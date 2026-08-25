// native/llama_wrapper.cpp
// llama.cpp C 封装层：供 Flutter FFI 调用。
// API 依据 third_party/llama.cpp/include/llama.h（2026-08 master）。
#include "llama_wrapper.h"

#include "llama.h"

#include <android/log.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "edge_llama", __VA_ARGS__)

namespace {

// 全局错误信息：约定"谁调用失败谁在同线程立即读取"，单工作线程模型下无并发写。
std::string g_last_error;

void set_error(const std::string& msg) { g_last_error = msg; }

// 默认采样参数（需求：先用默认参数，后续再做配置页）
constexpr int32_t kDefaultTopK = 40;
constexpr float kDefaultTopP = 0.9f;
constexpr float kDefaultTemp = 0.7f;
constexpr float kDefaultRepeatPenalty = 1.1f;

// 返回 s 的最长合法 UTF-8 前缀字节数（完整序列；截断在多字节序列中间时停下）。
// 目的：token piece 可能切断多字节字符（中文常见），必须缓冲拼接后再回调，
// 否则 Dart 侧 toDartString 会产生乱码。
size_t utf8_valid_prefix(const std::string& s) {
    size_t i = 0;
    const size_t n = s.size();
    while (i < n) {
        const unsigned char c = (unsigned char)s[i];
        size_t len = 0;
        if (c < 0x80) {
            len = 1;
        } else if ((c & 0xE0) == 0xC0) {
            len = 2;
        } else if ((c & 0xF0) == 0xE0) {
            len = 3;
        } else if ((c & 0xF8) == 0xF0) {
            len = 4;
        } else {
            break; // 非法首字节
        }
        if (i + len > n) {
            break; // 序列不完整（尾部截断）
        }
        for (size_t j = 1; j < len; j++) {
            if (((unsigned char)s[i + j] & 0xC0) != 0x80) {
                return i; // 后续字节非法：前缀止于 i
            }
        }
        i += len;
    }
    return i;
}

} // namespace

struct EdgeContext {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    const llama_vocab* vocab = nullptr;
    std::string desc;
    std::string chat_template;
    std::atomic<bool> abort_flag{false};
};

extern "C" {

void edge_llama_backend_init(void) {
    llama_backend_init();
}

static bool edge_abort_cb(void* data) {
    auto* ectx = static_cast<EdgeContext*>(data);
    return ectx != nullptr && ectx->abort_flag.load(std::memory_order_relaxed);
}

// 进度 trampoline：llama.cpp 要求回调返回 bool（false 中止加载），
// 而 Dart NativeCallable.listener 只支持 void 返回——包一层恒返回 true
static bool progress_trampoline(float progress, void* user_data) {
    auto cb = reinterpret_cast<edge_llama_progress_callback>(user_data);
    if (cb != nullptr) {
        cb(progress, nullptr);
    }
    return true; // 永不中止加载
}

EdgeContext* edge_llama_load_model(
    const char* path,
    int n_gpu_layers,
    int use_mmap,
    edge_llama_progress_callback progress_cb,
    void* progress_data
) {
    if (path == nullptr || path[0] == '\0') {
        set_error("model path is empty");
        return nullptr;
    }

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    mparams.load_mode = (use_mmap != 0) ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE;
    // 进度回调经 trampoline 适配（Dart 侧回调为 void 签名）
    mparams.progress_callback = &progress_trampoline;
    mparams.progress_callback_user_data = reinterpret_cast<void*>(progress_cb);

    llama_model* model = llama_model_load_from_file(path, mparams);
    if (model == nullptr) {
        set_error(std::string("failed to load model: ") + path);
        return nullptr;
    }

    auto* ectx = new EdgeContext();
    ectx->model = model;
    ectx->vocab = llama_model_get_vocab(model);

    char desc_buf[256];
    llama_model_desc(model, desc_buf, sizeof(desc_buf));
    ectx->desc = desc_buf;

    const char* tmpl = llama_model_chat_template(model, nullptr);
    if (tmpl != nullptr) {
        ectx->chat_template = tmpl;
    }
    return ectx;
}

const char* edge_llama_model_desc(EdgeContext* ectx) {
    return ectx != nullptr ? ectx->desc.c_str() : "";
}

const char* edge_llama_chat_template(EdgeContext* ectx) {
    return ectx != nullptr ? ectx->chat_template.c_str() : "";
}

int edge_llama_start_context(EdgeContext* ectx, int n_ctx, int n_batch, int n_threads) {
    if (ectx == nullptr || ectx->model == nullptr) {
        set_error("invalid context: model not loaded");
        return -1;
    }
    if (ectx->ctx != nullptr) {
        llama_free(ectx->ctx);
        ectx->ctx = nullptr;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = (uint32_t)n_ctx;
    cparams.n_batch = (uint32_t)n_batch;
    // 线程数：>0 用配置值；0 = llama.cpp 默认（全部核心）
    if (n_threads > 0) {
        cparams.n_threads = (int32_t)n_threads;
        cparams.n_threads_batch = (int32_t)n_threads;
    }
    // abort 回调：CPU 计算期间轮询，支持跨线程中止长计算
    cparams.abort_callback = edge_abort_cb;
    cparams.abort_callback_data = ectx;

    ectx->ctx = llama_init_from_model(ectx->model, cparams);
    if (ectx->ctx == nullptr) {
        set_error("failed to create inference context (check n_ctx / memory)");
        return -1;
    }
    return 0;
}

int edge_llama_apply_chat_template(
        EdgeContext* ectx,
        const char* const* roles,
        const char* const* contents,
        int n_msg,
        int add_ass,
        char* out_buf,
        int out_size) {
    if (ectx == nullptr || ectx->model == nullptr) {
        set_error("invalid context: model not loaded");
        return -1;
    }
    if (n_msg < 0 || (n_msg > 0 && (roles == nullptr || contents == nullptr))) {
        set_error("invalid message arrays");
        return -1;
    }

    std::vector<llama_chat_message> msgs;
    msgs.reserve((size_t)n_msg);
    for (int i = 0; i < n_msg; i++) {
        msgs.push_back({roles[i], contents[i]});
    }

    // 模型自带模板为空时传 nullptr → llama.cpp 回退 chatml
    const char* tmpl = ectx->chat_template.empty() ? nullptr : ectx->chat_template.c_str();

    const int32_t needed = llama_chat_apply_template(
            tmpl, msgs.data(), msgs.size(), add_ass != 0, out_buf, out_size);
    LOGI("apply_chat_template: src=%s needed=%d out=%.120s",
         tmpl == nullptr ? "<default-chatml>" : ectx->chat_template.substr(0, 80).c_str(),
         needed, out_buf != nullptr && needed > 0 ? out_buf : "(probe)");
    if (needed < 0) {
        set_error("failed to apply chat template");
        return -1;
    }
    return needed;
}

int edge_llama_decode(
        EdgeContext* ectx,
        const char* prompt,
        int max_tokens,
        float top_k,
        float top_p,
        float temp,
        float repeat_penalty,
        edge_llama_token_callback callback,
        void* user_data) {
    if (ectx == nullptr || ectx->ctx == nullptr) {
        set_error("invalid context: not started");
        return -1;
    }
    if (prompt == nullptr) {
        set_error("prompt is null");
        return -1;
    }

    llama_context* ctx = ectx->ctx;
    const llama_vocab* vocab = ectx->vocab;

    ectx->abort_flag.store(false, std::memory_order_relaxed);

    // 1. 提示词分词。parse_special=true：模板输出的 <|im_start|> 等特殊标记
    //    需编码为单个特殊 token；add_special=true：由模型配置决定是否加 BOS。
    //    探测调用（tokens=nullptr, n_max=0）返回负值 = 所需 token 数（API 语义，
    //    参见 examples/simple/simple.cpp），取反获得实际长度。
    const size_t prompt_len = strlen(prompt);
    LOGI("decode: max_tokens=%d prompt_len=%zu head=%.100s tail=%.60s",
         max_tokens, prompt_len, prompt,
         prompt_len > 60 ? prompt + prompt_len - 60 : "");
    int32_t n_prompt = -llama_tokenize(vocab, prompt, (int32_t)prompt_len,
                                       nullptr, 0, true, true);
    if (n_prompt <= 0) {
        set_error("failed to tokenize prompt");
        return -1;
    }
    std::vector<llama_token> prompt_tokens((size_t)n_prompt);
    if (llama_tokenize(vocab, prompt, (int32_t)prompt_len, prompt_tokens.data(),
                       n_prompt, true, true) < 0) {
        set_error("failed to tokenize prompt");
        return -1;
    }

    const uint32_t n_batch = llama_n_batch(ctx);
    if ((size_t)n_prompt + (size_t)max_tokens > (size_t)llama_n_ctx(ctx)) {
        // 超出上下文窗口：由上层裁剪历史后重试
        set_error("prompt + max_tokens exceeds context window (n_ctx)");
        return -2;
    }

    // 2. 每轮对话重新填充（简单可靠；移动端小模型 prefill 足够快）
    llama_memory_clear(llama_get_memory(ctx), false);

    // 3. Prefill：按 n_batch 分块喂入提示词
    for (int32_t i = 0; i < n_prompt; i += (int32_t)n_batch) {
        const int32_t n = std::min((int32_t)n_batch, n_prompt - i);
        llama_batch batch = llama_batch_get_one(prompt_tokens.data() + i, n);
        if (llama_decode(ctx, batch) != 0) {
            set_error("failed to prefill prompt");
            return -1;
        }
        if (ectx->abort_flag.load(std::memory_order_relaxed)) {
            return 1;
        }
    }

    // 4. 采样链（参数由调用方传入；<=0 时回退内置默认值）
    const float use_top_k = top_k > 0 ? top_k : (float)kDefaultTopK;
    const float use_top_p = top_p > 0 ? top_p : kDefaultTopP;
    const float use_temp = temp > 0 ? temp : kDefaultTemp;
    const float use_penalty = repeat_penalty > 0 ? repeat_penalty : kDefaultRepeatPenalty;
    LOGI("sample params: top_k=%.1f top_p=%.2f temp=%.2f penalty=%.2f",
         use_top_k, use_top_p, use_temp, use_penalty);

    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler* smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(
            llama_vocab_n_tokens(vocab), 64, use_penalty, 0.0f, 0.0f));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k((int32_t)use_top_k));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(use_top_p, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(use_temp));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(0));

    // 5. 自回归生成
    std::string utf8_buf; // 多字节字符拼接缓冲
    int n_generated = 0;
    int result = 0;

    while (n_generated < max_tokens) {
        if (ectx->abort_flag.load(std::memory_order_relaxed)) {
            result = 1;
            break;
        }

        llama_token new_token = llama_sampler_sample(smpl, ctx, -1);

        if (llama_vocab_is_eog(vocab, new_token)) {
            break;
        }

        // token → piece（special=false：不渲染特殊标记文本）
        char piece_buf[128];
        const int32_t piece_len = llama_token_to_piece(vocab, new_token, piece_buf,
                                                       sizeof(piece_buf), 0, false);
        if (piece_len > 0) {
            utf8_buf.append(piece_buf, (size_t)piece_len);
            const size_t emit_len = utf8_valid_prefix(utf8_buf);
            if (emit_len > 0) {
                if (callback != nullptr) {
                    // Dart listener 为异步投递，栈上字符串回调返回后即失效：
                    // 拷贝到堆，由 Dart 读取后经 edge_llama_free_piece 释放
                    char* copy = strdup(utf8_buf.substr(0, emit_len).c_str());
                    callback(copy, user_data);
                }
                utf8_buf.erase(0, emit_len);
            }
        }
        n_generated++;

        // 喂回模型继续生成
        llama_batch batch = llama_batch_get_one(&new_token, 1);
        if (llama_decode(ctx, batch) != 0) {
            set_error("failed to decode token");
            result = -1;
            break;
        }
    }

    // 冲刷残留的不完整 UTF-8（理论仅出现在异常截断时）
    if (result == 0 && !utf8_buf.empty() && callback != nullptr) {
        char* copy = strdup(utf8_buf.c_str());
        callback(copy, user_data);
    }

    LOGI("decode done: result=%d n_generated=%d", result, n_generated);
    llama_sampler_free(smpl);
    return result;
}

void edge_llama_abort(EdgeContext* ectx) {
    if (ectx != nullptr) {
        ectx->abort_flag.store(true, std::memory_order_relaxed);
    }
}

void edge_llama_free_piece(char* piece) {
    free(piece);
}

void edge_llama_free_context(EdgeContext* ectx) {
    if (ectx == nullptr) {
        return;
    }
    if (ectx->ctx != nullptr) {
        llama_free(ectx->ctx);
    }
    if (ectx->model != nullptr) {
        llama_model_free(ectx->model);
    }
    delete ectx;
}

const char* edge_llama_get_last_error(void) {
    return g_last_error.c_str();
}

} // extern "C"
