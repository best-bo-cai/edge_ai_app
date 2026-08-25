// native/llama_wrapper.h
#ifndef EDGE_LLAMA_WRAPPER_H
#define EDGE_LLAMA_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 上下文结构体（不透明指针，内部持有 llama_model/llama_context）
typedef struct EdgeContext EdgeContext;

// Token 流式回调：piece 为 UTF-8 完整片段（跨 token 的多字节字符已做缓冲拼接），
// user_data 原样透传。回调可能在任意线程触发，接收方需自行保证线程安全。
typedef void (*edge_llama_token_callback)(const char* piece, void* user_data);

// 模型加载进度回调：progress ∈ [0.0, 1.0]。
// 由 llama.cpp 在读取模型文件时触发（可能在加载线程外调用）。
// 注意：签名为 void（适配 Dart NativeCallable.listener 的 void 限制），
// 永不中止加载——内部由静态 trampoline 以 return true 适配 llama.cpp。
typedef void (*edge_llama_progress_callback)(float progress, void* user_data);

/**
 * 初始化后端（进程内调用一次）
 */
void edge_llama_backend_init(void);

/**
 * 加载模型文件（GGUF）
 * @param path 模型文件路径
 * @param n_gpu_layers GPU 层数（0 = 纯 CPU；Android 上通常传 0）
 * @param use_mmap 是否使用内存映射（推荐 1）
 * @param progress_cb 加载进度回调（可为 NULL）
 * @param progress_data 进度回调透传数据
 * @return EdgeContext 指针，失败返回 NULL（错误信息用 edge_llama_get_last_error 获取）
 */
EdgeContext* edge_llama_load_model(
    const char* path,
    int n_gpu_layers,
    int use_mmap,
    edge_llama_progress_callback progress_cb,
    void* progress_data
);

/**
 * 释放 token 回调投递的字符串拷贝。
 * Dart 侧 NativeCallable.listener 为异步投递：回调返回后原指针即失效，
 * 因此回调传出的 piece 均为堆上拷贝，由 Dart 读取后调用此函数释放。
 */
void edge_llama_free_piece(char* piece);

/**
 * 获取模型描述（架构/量化等信息，用于 UI 展示）
 * @return 模型描述字符串（随上下文存活，勿释放）
 */
const char* edge_llama_model_desc(EdgeContext* ectx);

/**
 * 获取模型内置聊天模板（Jinja 文本；可能为空串，表示无模板）
 * @return 模板字符串（随上下文存活，勿释放）
 */
const char* edge_llama_chat_template(EdgeContext* ectx);

/**
 * 创建推理上下文
 * @param ectx edge_llama_load_model 返回的句柄
 * @param n_ctx 上下文窗口大小（token 数）
 * @param n_batch 批处理大小
 * @param n_threads CPU 推理线程数（0 = llama.cpp 默认全部核心）
 * @return 0 成功，非 0 失败
 */
int edge_llama_start_context(EdgeContext* ectx, int n_ctx, int n_batch, int n_threads);

/**
 * 按模型内置模板格式化对话消息
 * @param ectx 模型句柄
 * @param roles 消息角色数组（"system"/"user"/"assistant"）
 * @param contents 消息内容数组（与 roles 一一对应）
 * @param n_msg 消息条数
 * @param add_ass 是否在末尾追加助手起始标记
 * @param out_buf 输出缓冲区
 * @param out_size 缓冲区大小
 * @return 所需字节数（含结尾 0）；大于 out_size 表示缓冲区不足；负数失败
 */
int edge_llama_apply_chat_template(
    EdgeContext* ectx,
    const char* const* roles,
    const char* const* contents,
    int n_msg,
    int add_ass,
    char* out_buf,
    int out_size
);

/**
 * 执行一次流式推理（阻塞直至生成结束/中止/达到 max_tokens）。
 * 采样参数由调用方传入（模型参数配置，需求文档 §4）；<=0 时使用内置默认值。
 * 每个生成出的文本片段通过 callback 流式回调。
 * @param prompt 已格式化的完整提示词
 * @param max_tokens 最大生成 token 数
 * @param top_k top-k 采样（<=0 用默认 40）
 * @param top_p top-p 采样（<=0 用默认 0.9）
 * @param temp 温度（<=0 用默认 0.7）
 * @param repeat_penalty 重复惩罚（<=0 用默认 1.1）
 * @param callback Token 回调（可为 NULL）
 * @param user_data 回调透传数据
 * @return 0 成功；1 被用户中止；负数失败
 */
int edge_llama_decode(
    EdgeContext* ectx,
    const char* prompt,
    int max_tokens,
    float top_k,
    float top_p,
    float temp,
    float repeat_penalty,
    edge_llama_token_callback callback,
    void* user_data
);

/**
 * 中止正在进行的 edge_llama_decode（线程安全，可在另一线程调用）
 */
void edge_llama_abort(EdgeContext* ectx);

/**
 * 释放上下文与其持有的模型资源
 */
void edge_llama_free_context(EdgeContext* ectx);

/**
 * 获取最近一次错误信息（在失败调用的同一线程立即读取）
 */
const char* edge_llama_get_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // EDGE_LLAMA_WRAPPER_H
