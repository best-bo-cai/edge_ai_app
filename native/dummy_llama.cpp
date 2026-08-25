// native/dummy_llama.cpp
// 兜底占位实现：当 third_party/llama.cpp 未克隆时保证工程可编译。
// 此时 libllama.so 仅提供"加载即失败"的桩实现，App 侧自动降级为 Mock 对话。

#include "llama_wrapper.h"

#include <string>

static std::string g_dummy_error = "llama.cpp not available (dummy build)";

extern "C" {

void edge_llama_backend_init(void) {}

EdgeContext* edge_llama_load_model(const char*, int, int,
                                   edge_llama_progress_callback, void*) {
    return nullptr;
}

const char* edge_llama_model_desc(EdgeContext*) { return ""; }
const char* edge_llama_chat_template(EdgeContext*) { return ""; }

int edge_llama_start_context(EdgeContext*, int, int, int) { return -1; }

int edge_llama_apply_chat_template(EdgeContext*, const char* const*, const char* const*,
                                   int, int, char*, int) {
    return -1;
}

int edge_llama_decode(EdgeContext*, const char*, int,
                      float, float, float, float,
                      edge_llama_token_callback, void*) {
    return -1;
}

void edge_llama_abort(EdgeContext*) {}

void edge_llama_free_piece(char*) {}

void edge_llama_free_context(EdgeContext*) {}

const char* edge_llama_get_last_error(void) { return g_dummy_error.c_str(); }

} // extern "C"
