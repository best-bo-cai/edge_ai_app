// native/dummy_llama.cpp
// MVP 版本占位文件（当 llama.cpp 未克隆时使用）
// 实际使用时请克隆 llama.cpp 并移除此文件

#include <stddef.h>

// 占位类型定义
typedef int32_t llama_token;
typedef struct llama_model llama_model;
typedef struct llama_context llama_context;
typedef struct llama_batch llama_batch;

// 占位函数实现
extern "C" {

void llama_backend_init(void) {}
void llama_backend_free(void) {}

llama_model* llama_load_model_from_file(const char*, void*) { return nullptr; }
void llama_free_model(llama_model*) {}

llama_context* llama_new_context_with_model(llama_model*, void*) { return nullptr; }
void llama_free(llama_context*) {}

llama_batch llama_batch_init(int, int, int) { return {}; }
void llama_batch_free(llama_batch) {}

int llama_decode(llama_context*, llama_batch) { return -1; }

std::vector<llama_token> llama_tokenize(llama_context*, const std::string&, bool) { return {}; }
llama_token llama_sampler_sample(void*, llama_context*, int) { return 0; }
std::string llama_token_to_piece(llama_context*, llama_token) { return ""; }
llama_token llama_token_eos(llama_model*) { return 0; }
int llama_vocab_type(llama_model*) { return 0; }

llama_model_params llama_model_default_params() { return {}; }
llama_context_params llama_context_default_params() { return {}; }

}
