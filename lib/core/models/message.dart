// lib/core/models/message.dart

/// 聊天消息模型
///
/// 助手消息由「思考内容」与「正文」两部分组成（四期需求 §2.1）：
/// - [reasoning]：思考内容（<think> 与 </think> 之间的推理过程），仅供查看
/// - [content]：正文（</think> 之后），语义与旧版单一 content 字段一致
///
/// 旧版混合存储（think 标签原样在 content 里）由 [splitLegacy] 懒拆分兼容。
class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final DateTime timestamp;
  final bool isStreaming;

  /// 思考内容（仅 assistant 消息可能有；空表示无思考）
  final String reasoning;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.isStreaming = false,
    this.reasoning = '',
  }) : timestamp = timestamp ?? DateTime.now();

  factory ChatMessage.user(String content) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.user,
      content: content,
    );
  }

  factory ChatMessage.assistant(String content,
      {bool isStreaming = false, String reasoning = ''}) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.assistant,
      content: content,
      isStreaming: isStreaming,
      reasoning: reasoning,
    );
  }

  /// 旧版混合存储懒拆分（四期需求 §2.3）：
  /// content 含 think 标签时拆为 reasoning + content；否则原样返回。
  static ChatMessage splitLegacy(ChatMessage msg) {
    if (msg.role != MessageRole.assistant) return msg;
    final parsed = ThinkSplitter.parse(msg.content);
    if (parsed.reasoning.isEmpty) return msg;
    return msg.copyWith(reasoning: parsed.reasoning, content: parsed.content);
  }

  ChatMessage copyWith({
    String? id,
    MessageRole? role,
    String? content,
    DateTime? timestamp,
    bool? isStreaming,
    String? reasoning,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
      reasoning: reasoning ?? this.reasoning,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role.name,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isStreaming': isStreaming,
      if (reasoning.isNotEmpty) 'reasoning': reasoning,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final msg = ChatMessage(
      id: json['id'] as String,
      role: MessageRole.values.firstWhere((e) => e.name == json['role']),
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isStreaming: json['isStreaming'] as bool? ?? false,
      reasoning: json['reasoning'] as String? ?? '',
    );
    return splitLegacy(msg);
  }
}

/// think 标签解析结果
class ThinkParseResult {
  final String reasoning;
  final String content;
  const ThinkParseResult(this.reasoning, this.content);
}

/// <think>...</think> 标签一次性解析（懒拆分 / 单测用）。
/// 与流式状态机 [ThinkStreamSplitter] 共享同一套标签语义。
class ThinkSplitter {
  // 相邻字符串字面量在编译期拼接（与 ThinkStreamSplitter 同一套标签语义）
  static const String openTag = '<th' 'ink>';
  static const String closeTag = '</th' 'ink>';

  static ThinkParseResult parse(String text) {
    final open = text.indexOf(openTag);
    if (open < 0) return ThinkParseResult('', text);

    // open 之前的正文保留（与流式状态机一致，不能丢弃）
    final prefix = text.substring(0, open);

    final close = text.indexOf(closeTag, open + openTag.length);
    if (close < 0) {
      // 未闭合：全部视为思考（生成中断场景）
      return ThinkParseResult(
          text.substring(open + openTag.length), prefix);
    }
    return ThinkParseResult(
      text.substring(open + openTag.length, close),
      // close 之后的后续同款标签按正文处理（§2.2 不二次切换）
      prefix + text.substring(close + closeTag.length),
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
