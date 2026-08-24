// lib/core/models/message.dart

/// 聊天消息模型
class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final DateTime timestamp;
  final bool isStreaming;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.isStreaming = false,
  }) : timestamp = timestamp ?? DateTime.now();

  factory ChatMessage.user(String content) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.user,
      content: content,
    );
  }

  factory ChatMessage.assistant(String content, {bool isStreaming = false}) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.assistant,
      content: content,
      isStreaming: isStreaming,
    );
  }

  ChatMessage copyWith({
    String? id,
    MessageRole? role,
    String? content,
    DateTime? timestamp,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role.name,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isStreaming': isStreaming,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: MessageRole.values.firstWhere((e) => e.name == json['role']),
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isStreaming: json['isStreaming'] as bool? ?? false,
    );
  }
}

/// 消息角色枚举
enum MessageRole {
  user,
  assistant,
  system,
}

/// 模型配置
class ModelConfig {
  final String id;
  final String name;
  final String path;
  final int nCtx;
  final int nGpuLayers;
  final int nThreads;
  final double temperature;
  final double topP;
  final int maxTokens;

  const ModelConfig({
    required this.id,
    required this.name,
    required this.path,
    this.nCtx = 2048,
    this.nGpuLayers = 20,
    this.nThreads = 4,
    this.temperature = 0.7,
    this.topP = 0.9,
    this.maxTokens = 512,
  });

  ModelConfig copyWith({
    String? id,
    String? name,
    String? path,
    int? nCtx,
    int? nGpuLayers,
    int? nThreads,
    double? temperature,
    double? topP,
    int? maxTokens,
  }) {
    return ModelConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      nCtx: nCtx ?? this.nCtx,
      nGpuLayers: nGpuLayers ?? this.nGpuLayers,
      nThreads: nThreads ?? this.nThreads,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      maxTokens: maxTokens ?? this.maxTokens,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'nCtx': nCtx,
      'nGpuLayers': nGpuLayers,
      'nThreads': nThreads,
      'temperature': temperature,
      'topP': topP,
      'maxTokens': maxTokens,
    };
  }

  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    return ModelConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['path'] as String,
      nCtx: json['nCtx'] as int? ?? 2048,
      nGpuLayers: json['nGpuLayers'] as int? ?? 20,
      nThreads: json['nThreads'] as int? ?? 4,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      topP: (json['topP'] as num?)?.toDouble() ?? 0.9,
      maxTokens: json['maxTokens'] as int? ?? 512,
    );
  }

  /// 默认配置（MVP 版本）
  /// 推荐使用 Qwen2.5-0.5B-Instruct-Q4_K_M.gguf (约 320MB)
  /// 下载地址：https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
  /// 注意：模型不打包进应用，统一由 ModelService 在运行时下载/导入到应用文档目录。
  /// path 为占位值，实际加载前需通过 ModelService 获取已下载模型的绝对路径。
  static const defaultConfig = ModelConfig(
    id: 'qwen2.5-0.5b',
    name: 'Qwen2.5 0.5B Instruct (Q4_K_M)',
    path: 'models/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    nCtx: 1024,  // PRD 要求：降低内存占用
    nGpuLayers: 0,  // MVP: CPU 推理，保证稳定性
    nThreads: 4,
    temperature: 0.7,  // PRD 固定值
    topP: 0.9,  // PRD 固定值
    maxTokens: 512,  // PRD 固定值
  );
}
