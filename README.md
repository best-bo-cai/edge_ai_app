# EdgeMind AI

完全离线、跨平台的端侧大模型对话应用。基于 Flutter + llama.cpp 构建，数据不出设备，零流量消耗，隐私安全。

## 核心特性

- **完全离线** — 所有推理在设备本地完成，无需网络
- **流式输出** — 实时逐字显示 AI 回复
- **模型管理** — 支持下载、导入、切换多个 GGUF 模型
- **跨平台** — Android 8.0+ / iOS 14.0+

## 快速开始

### 环境要求

- Flutter SDK >= 3.5
- Android NDK >= 26（Android 构建时需要）

### 安装与运行

```bash
# 安装依赖
flutter pub get

# 在连接的 Android 设备 / 模拟器上运行
flutter run

# 构建发布 APK
flutter build apk --release
```

### 准备模型文件

应用运行需要 `.gguf` 格式的量化模型。三种获取方式：

1. **一键下载** — 在 App 的"模型"页面点击推荐模型下载
2. **自定义 URL** — 粘贴 HuggingFace 直链下载
3. **本地导入** — 从其他渠道下载的 GGUF 文件通过文件选择器导入

当前仓库 `assets/models/` 目录下包含一个开发用模型：
`qwen2.5-0.5b-instruct-q4_k_m.gguf`（约 468MB）

也可通过脚本下载：
```bash
bash scripts/download_model.sh
```

## 项目结构

```
edge_ai_app/
├── lib/
│   ├── main.dart                          # 应用入口
│   ├── core/
│   │   ├── engine/llama_engine.dart       # FFI 引擎封装
│   │   ├── models/message.dart            # 数据模型
│   │   └── services/
│   │       ├── chat_service.dart          # 聊天业务逻辑
│   │       └── model_service.dart         # 模型管理
│   └── features/
│       ├── chat/chat_screen.dart           # 聊天界面
│       └── settings/model_management_screen.dart  # 模型管理界面
├── native/
│   ├── llama_wrapper.h / .cpp             # C++ FFI 桥接层
│   ├── dummy_llama.cpp                    # Mock 占位实现
│   ├── CMakeLists.txt                     # CMake 跨平台构建
│   └── scripts/build_android.sh / build_ios.sh
├── assets/models/                         # GGUF 模型文件
├── android/                               # Android 工程
├── docs/                                  # 项目文档
└── scripts/download_model.sh              # 模型下载脚本
```

## MVP 状态

当前版本为 MVP，AI 推理使用 Mock 模式（返回模拟文本）。要集成真实推理：

```bash
# 1. 克隆 llama.cpp
mkdir -p native/third_party
cd native/third_party
git clone https://github.com/ggerganov/llama.cpp.git

# 2. 编译原生库
cd ..
bash scripts/build_android.sh

# 3. 取消 lib/core/engine/llama_engine.dart 中的 FFI 调用注释
```

## 功能路线图

- [x] 基础聊天 UI（Material 3）
- [x] 流式消息输出（Mock）
- [x] 模型下载 / 导入 / 管理
- [x] 多模型切换
- [ ] llama.cpp FFI 真实集成
- [ ] Isolate 推理线程（避免阻塞 UI）
- [ ] 参数调节（temperature, topP 等）
- [ ] GPU 加速推理
- [ ] 对话历史本地持久化

## 许可证

MIT License
