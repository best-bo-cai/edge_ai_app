# EdgeMind AI

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS-green.svg)](https://flutter.dev)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.5-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![llama.cpp](https://img.shields.io/badge/engine-llama.cpp-8A2BE2)](https://github.com/ggml-org/llama.cpp)
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen)](test/)

完全离线的端侧大模型对话应用，并可将本地模型以 **OpenAI / Anthropic 兼容 API** 的形式提供给同设备的其他 App 使用。基于 Flutter + llama.cpp 构建，推理全部在设备本地完成，数据不出设备，零流量消耗。

## 核心特性

- **本地离线推理** — llama.cpp FFI 直连，流式逐字输出，加载进度实时可见；模型加载与推理在独立 Isolate 执行，UI 不阻塞
- **模型广场** — 一键下载推荐模型（断点续传 / 失败重试 / SHA256 校验）、自定义 HuggingFace 直链、本地 GGUF 文件导入
- **模型热切换** — 切换模型无需重启应用，切换后自动开启绑定新模型的新会话
- **多会话管理** — 会话持久化（sqflite），支持新建 / 切换 / 重命名 / 删除，进程被杀后自动恢复历史与会话状态
- **每模型参数配置** — 采样参数（temperature / top_k / top_p / repeat_penalty 等）即时生效；上下文参数（n_ctx / n_threads）自动触发热重载；支持按模型配置 system prompt
- **本地 API 服务** — loopback HTTP 服务，兼容 OpenAI（`/v1/chat/completions`）与 Anthropic（`/v1/messages`）双协议，支持 SSE 流式，API key 鉴权，模型严格匹配（404），与 App 内对话共享引擎并排队执行

## 目录

- [快速开始](#快速开始)
- [本地 API 服务](#本地-api-服务)
- [项目结构](#项目结构)
- [开发指南](#开发指南)
- [常见问题](#常见问题)
- [许可证](#许可证)

## 快速开始

### 环境要求

- Flutter SDK >= 3.5
- Android NDK >= 26（Android 构建时需要）
- 一台 Android 8.0+ / iOS 14.0+ 设备（推理依赖原生库，模拟器表现有限）

### 安装与运行

```bash
git clone https://github.com/best-bo-cai/edge_ai_app.git
cd edge_ai_app
flutter pub get
flutter run                 # 连接设备直接运行
flutter build apk --release # 或构建发布包
```

### 准备模型文件

应用使用 `.gguf` 格式的量化模型，三种获取方式：

1. **一键下载** — 在 App「模型」页选择推荐模型下载（支持镜像源）
2. **自定义 URL** — 粘贴 HuggingFace 直链下载
3. **本地导入** — 通过文件选择器导入已有 GGUF 文件

开发用模型可脚本下载至 `assets/models/`：

```bash
bash scripts/download_model.sh
```

### 体验对话

1. 在「模型」页下载或导入模型（如 `qwen3.5-0.8b-q4-k-m`）
2. 进入「对话」页发送消息，观察流式输出与加载进度条
3. 点击 AppBar 的调节图标进入参数配置页，调整采样参数后立即生效

## 本地 API 服务

在「API 服务」页开启服务后，同设备的其他 App 可以用任意 OpenAI / Anthropic SDK 接入本地模型：

| 端点 | 协议 | 说明 |
|------|------|------|
| `GET /v1/models` | OpenAI | 已安装模型列表 |
| `POST /v1/chat/completions` | OpenAI | 对话补全，支持 `stream: true` SSE 流式 |
| `POST /v1/messages` | Anthropic | 消息生成，支持 SSE 事件流（`message_start → content_block_delta → message_stop`） |

调用示例：

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer <你的APIKey>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-0.8b-q4-k-m",
    "stream": true,
    "messages": [{"role": "user", "content": "你好"}]
  }'
```

要点：

- **鉴权**：支持 `Authorization: Bearer`（OpenAI 风格）与 `x-api-key`（Anthropic 风格），无 key 返回 401
- **严格匹配**：请求未安装的模型返回 404 + `model_not_found`
- **排队执行**：API 请求与 App 内对话共享同一推理引擎，经互斥锁排队串行执行，互不打断
- **服务自恢复**：开关状态持久化，退出前开着则下次启动自动恢复
- **调用审计**：完整请求 / 响应内容与 token 统计落库（`api_call_logs`）

## 项目结构

```
edge_ai_app/
├── lib/
│   ├── main.dart                          # 应用入口与服务初始化
│   ├── core/
│   │   ├── engine/llama_engine.dart       # llama.cpp FFI 封装（Isolate + 流式回调）
│   │   ├── models/                        # 数据模型（消息 / 会话 / 模型参数）
│   │   └── services/
│   │       ├── api_server/                # 本地 API 服务（路由 / 鉴权 / 双协议 handler / 推理调度）
│   │       ├── chat_service.dart          # 对话业务（引擎锁 / prompt 构建）
│   │       ├── conversation_service.dart  # 多会话管理
│   │       ├── model_params_service.dart  # 每模型参数
│   │       ├── model_service.dart         # 模型管理（ChangeNotifier 广播）
│   │       ├── download_manager.dart      # 下载（断点续传 / 校验）
│   │       └── app_database.dart          # sqflite 持久化
│   └── features/
│       ├── chat/                          # 对话页 + 会话列表页
│       └── settings/                      # 模型管理 / 参数配置 / API 服务页
├── native/
│   ├── llama_wrapper.h / .cpp             # C++ FFI 桥接层
│   ├── third_party/                       # llama.cpp 源码（不入库，构建时克隆）
│   └── scripts/build_android.sh           # 原生库构建脚本
├── test/                                  # 单元测试（引擎 / 下载 / API 协议层等）
├── assets/models/                         # GGUF 模型文件（不入库）
└── docs/                                  # 需求文档与 ADR（本地留存）
```

## 开发指南

### 构建原生推理库

首次构建需要克隆并编译 llama.cpp：

```bash
mkdir -p native/third_party
cd native/third_party
git clone https://github.com/ggml-org/llama.cpp.git
cd ..
bash scripts/build_android.sh
```

桌面 / 单测环境无 `libllama.so` 时，引擎自动降级为 Mock 输出，不阻塞开发与测试。

### 运行测试

```bash
flutter test
```

### 架构速览

- **推理线程模型**：模型加载与 decode 在独立 Isolate 阻塞执行；token 经 `NativeCallable.listener` 回流主 Isolate 实现真实流式
- **互斥锁**：App 内对话与 API 请求经同一把引擎锁排队，任一时刻只有一个推理在跑
- **热切换**：`ModelService` 基于 `ChangeNotifier` 广播模型变化，会话层自动归档旧会话并创建新模型绑定的新会话

## 常见问题

### Q: 对话报错 `failed to tokenize prompt`？

该问题已在早前版本修复（llama.cpp tokenization 探测调用返回负值需取反）。若使用旧版自行编译的原生库，请重新执行 `bash scripts/build_android.sh`。

### Q: API 服务能被局域网内其他设备访问吗？

不能，服务仅监听 `127.0.0.1`（loopback），只有同设备内的 App 可访问。这是隐私与安全的设计约束。

### Q: 为什么请求返回 404？

API 采用模型严格匹配（ADR-0002）：`model` 字段必须与已安装模型 id 完全一致。可先调用 `GET /v1/models` 获取可用列表。

### Q: 模型文件和 llama.cpp 源码为什么不在仓库里？

GGUF 权重文件体积大、llama.cpp 属第三方源码，均不提交远程仓库。构建方式见「开发指南」。

## 功能路线图

- [x] 基础聊天 UI（Material 3）+ 流式输出
- [x] llama.cpp FFI 真实推理（Isolate 线程 + 流式回调）
- [x] 模型下载（断点续传 / 校验）/ 导入 / 热切换
- [x] 多会话管理与持久化
- [x] 每模型参数配置（采样即时生效 + 上下文热重载）
- [x] 本地 API 服务（OpenAI / Anthropic 兼容 + SSE + 鉴权 + 排队）
- [ ] API 调用日志查看页
- [ ] 更多采样参数（min_p / seed 等）
- [ ] GPU 加速推理

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
