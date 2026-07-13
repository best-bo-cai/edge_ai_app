// native/llama_wrapper.cpp
#include "llama_wrapper.h"
#include "third_party/llama.cpp/llama.h"

#include <string>
#include <vector>
#include <cstring>
#include <iostream>

// 内部上下文结构体
struct EdgeContext {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    llama_batch batch;
    
    // 回调函数类型定义
    using TokenCallback = void(*)(const char* token, void* user_data);
    TokenCallback token_callback = nullptr;
    void* user_data = nullptr;
    
    // 生成状态
    std::vector<llama_token> current_tokens;
    bool is_generating = false;
};

// 全局错误信息（线程局部存储）
thread_local std::string g_last_error;

extern "C" {

EdgeContext* edge_llama_load_model(
    const char* path,
    int n_gpu_layers,
    int n_threads,
    int use_mmap
) {
    if (!path) {
        g_last_error = "Model path is null";
        return nullptr;
    }

    // 初始化 llama 后端
    llama_backend_init();

    // 模型参数
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = n_gpu_layers;
    model_params.use_mmap = (use_mmap != 0);
    
    #ifdef GGML_USE_METAL
    model_params.n_gpu_layers = n_gpu_layers; // Metal GPU 加速
    #endif

    // 加载模型
    llama_model* model = llama_load_model_from_file(path, model_params);
    if (!model) {
        g_last_error = "Failed to load model: " + std::string(path);
        llama_backend_free();
        return nullptr;
    }

    // 创建上下文包装
    EdgeContext* ectx = new EdgeContext();
    ectx->model = model;
    ectx->batch = llama_batch_init(512, 0, 1);

    std::cout << "Model loaded successfully: " << path << std::endl;
    return ectx;
}

EdgeContext* edge_llama_new_context(
    EdgeContext* ectx,
    int n_ctx,
    int n_batch,
    void* callback_ptr
) {
    if (!ectx || !ectx->model) {
        g_last_error = "Invalid model context";
        return nullptr;
    }

    // 上下文参数
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = n_ctx;
    ctx_params.n_batch = n_batch;
    ctx_params.n_threads = 4;
    ctx_params.n_threads_batch = 4;

    // 创建推理上下文
    llama_context* ctx = llama_new_context_with_model(ectx->model, ctx_params);
    if (!ctx) {
        g_last_error = "Failed to create context";
        return nullptr;
    }

    ectx->ctx = ctx;
    ectx->token_callback = reinterpret_cast<EdgeContext::TokenCallback>(callback_ptr);

    std::cout << "Context created: n_ctx=" << n_ctx << ", n_batch=" << n_batch << std::endl;
    return ectx;
}

int edge_llama_decode(
    EdgeContext* ectx,
    const char* prompt,
    int max_tokens,
    void* user_data
) {
    if (!ectx || !ectx->ctx || !prompt) {
        g_last_error = "Invalid parameters";
        return -1;
    }

    ectx->user_data = user_data;
    ectx->is_generating = true;
    ectx->current_tokens.clear();

    // Tokenize 提示词
    const std::string prompt_str(prompt);
    std::vector<llama_token> tokens_list = llama_tokenize(ectx->ctx, prompt_str, false);

    // 设置批处理
    ectx->batch.n_tokens = static_cast<int32_t>(tokens_list.size());
    for (size_t i = 0; i < tokens_list.size(); ++i) {
        ectx->batch.token[i] = tokens_list[i];
        ectx->batch.pos[i] = static_cast<int32_t>(i);
        ectx->batch.n_seq_id[i] = 1;
        ectx->batch.seq_id[i][0] = 0;
        ectx->batch.logits[i] = false;
    }
    ectx->batch.logits[ectx->batch.n_tokens - 1] = true; // 最后一个 token 需要 logits

    // 预填充（Prompt Processing）
    if (llama_decode(ectx->ctx, ectx->batch) != 0) {
        g_last_error = "Failed to decode prompt";
        ectx->is_generating = false;
        return -1;
    }

    // 自回归生成
    int n_past = ectx->batch.n_tokens;
    int n_generated = 0;

    while (n_generated < max_tokens) {
        // 采样下一个 token
        llama_token new_token_id = llama_sampler_sample(nullptr, ectx->ctx, -1);

        // 检查结束条件
        if (llama_vocab_type(ectx->model) == LLAMA_VOCAB_TYPE_SPM) {
            if (new_token_id == llama_token_eos(ectx->model)) {
                break; // EOS token
            }
        }

        // 转换为文本
        std::string piece = llama_token_to_piece(ectx->ctx, new_token_id);
        
        // 调用回调（流式输出）
        if (ectx->token_callback && !piece.empty()) {
            ectx->token_callback(piece.c_str(), user_data);
        }

        ectx->current_tokens.push_back(new_token_id);
        n_generated++;

        // 准备下一个 batch
        ectx->batch.n_tokens = 1;
        ectx->batch.token[0] = new_token_id;
        ectx->batch.pos[0] = n_past;
        ectx->batch.n_seq_id[0] = 1;
        ectx->batch.seq_id[0][0] = 0;
        ectx->batch.logits[0] = true;

        n_past++;

        // 解码
        if (llama_decode(ectx->ctx, ectx->batch) != 0) {
            g_last_error = "Failed to decode token";
            break;
        }
    }

    ectx->is_generating = false;
    std::cout << "Generation completed: " << n_generated << " tokens" << std::endl;
    return 0;
}

void edge_llama_free_context(EdgeContext* ectx) {
    if (!ectx) return;

    if (ectx->ctx) {
        llama_free(ectx->ctx);
    }
    if (ectx->model) {
        llama_free_model(ectx->model);
    }
    if (ectx->batch.token) {
        llama_batch_free(ectx->batch);
    }

    delete ectx;
    llama_backend_free();

    std::cout << "Context freed" << std::endl;
}

const char* edge_llama_get_last_error(void) {
    return g_last_error.c_str();
}

} // extern "C"
