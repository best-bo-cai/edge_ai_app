// native/llama_wrapper.h
#ifndef EDGE_LLAMA_WRAPPER_H
#define EDGE_LLAMA_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 上下文结构体（不透明指针）
typedef struct EdgeContext EdgeContext;

/**
 * 加载模型文件
 * @param path 模型文件路径（GGUF 格式）
 * @param n_gpu_layers GPU 层数（0 表示纯 CPU）
 * @param n_threads CPU 线程数
 * @param use_mmap 是否使用内存映射
 * @return 模型指针，失败返回 NULL
 */
EdgeContext* edge_llama_load_model(
    const char* path,
    int n_gpu_layers,
    int n_threads,
    int use_mmap
);

/**
 * 创建推理上下文
 * @param ectx 模型上下文
 * @param n_ctx 上下文窗口大小
 * @param n_batch 批处理大小
 * @param callback_ptr Token 回调函数指针
 * @return 上下文指针，失败返回 NULL
 */
EdgeContext* edge_llama_new_context(
    EdgeContext* ectx,
    int n_ctx,
    int n_batch,
    void* callback_ptr
);

/**
 * 执行推理（流式）
 * @param ectx 上下文指针
 * @param prompt 输入提示词
 * @param max_tokens 最大生成 token 数
 * @param user_data 用户数据指针
 * @return 0 表示成功，非 0 表示失败
 */
int edge_llama_decode(
    EdgeContext* ectx,
    const char* prompt,
    int max_tokens,
    void* user_data
);

/**
 * 释放上下文资源
 * @param ectx 上下文指针
 */
void edge_llama_free_context(EdgeContext* ectx);

/**
 * 获取最后错误信息
 * @return 错误信息字符串
 */
const char* edge_llama_get_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // EDGE_LLAMA_WRAPPER_H
