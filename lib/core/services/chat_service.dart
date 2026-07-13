// lib/core/services/chat_service.dart
import 'dart:async';
import '../engine/llama_engine.dart';
import '../models/message.dart';

/// 聊天服务（MVP 版本）
class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final LlamaEngine _engine = LlamaEngine();
  final List<ChatMessage> _messageHistory = [];
  ModelConfig _currentConfig = ModelConfig.defaultConfig;
  
  bool _isGenerating = false;
  StreamController<String>? _streamController;

  /// 当前配置
  ModelConfig get currentConfig => _currentConfig;
  
  /// 消息历史
  List<ChatMessage> get messageHistory => List.unmodifiable(_messageHistory);
  
  /// 是否正在生成
  bool get isGenerating => _isGenerating;

  /// 初始化服务
  Future<bool> initialize() async {
    return await _engine.initialize();
  }

  /// 加载模型
  Future<bool> loadModel(ModelConfig config) async {
    _currentConfig = config;
    
    final loaded = await _engine.loadModel(
      modelPath: config.path,
      nGpuLayers: config.nGpuLayers,
      nThreads: config.nThreads,
    );

    if (loaded) {
      await _engine.createContext(
        nCtx: config.nCtx,
        nBatch: 512,
      );
    }

    return loaded;
  }

  /// 发送消息并获取流式回复
  Stream<String> sendMessage(String userMessage) async* {
    if (_isGenerating) {
      throw StateError('Already generating response');
    }

    _isGenerating = true;
    
    try {
      // 添加用户消息到历史
      final userMsg = ChatMessage.user(userMessage);
      _messageHistory.add(userMsg);

      // 创建占位符助手消息
      final assistantMsg = ChatMessage.assistant('', isStreaming: true);
      _messageHistory.add(assistantMsg);

      // 构建提示词（包含上下文）
      final prompt = _buildPrompt(userMessage);

      // 启动流式生成
      final stream = _engine.generateStream(prompt);
      
      String accumulatedResponse = '';
      
      await for (final token in stream) {
        accumulatedResponse += token;
        yield token;
        
        // 更新助手消息内容
        final lastIndex = _messageHistory.length - 1;
        _messageHistory[lastIndex] = assistantMsg.copyWith(
          content: accumulatedResponse,
        );
      }

      // 标记流式结束
      final lastIndex = _messageHistory.length - 1;
      _messageHistory[lastIndex] = _messageHistory[lastIndex].copyWith(
        isStreaming: false,
      );

    } finally {
      _isGenerating = false;
    }
  }

  /// 构建提示词（包含上下文）
  String _buildPrompt(String currentUserMessage) {
    // MVP 版本：简单提示词，符合 Qwen2.5 格式
    // 参考：https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct
    final buffer = StringBuffer();
    
    // System prompt
    buffer.writeln('<|im_start|>system');
    buffer.writeln('You are a helpful AI assistant. Respond in Chinese.');
    buffer.writeln('<|im_end|>');
    
    // User message
    buffer.writeln('<|im_start|>user');
    buffer.writeln(currentUserMessage);
    buffer.writeln('<|im_end|>');
    
    // Assistant response start
    buffer.write('<|im_start|>assistant\n');
    
    return buffer.toString();
  }

  /// 清除对话历史
  void clearHistory() {
    _messageHistory.clear();
  }

  /// 删除指定消息
  void removeMessage(String messageId) {
    _messageHistory.removeWhere((msg) => msg.id == messageId);
  }

  /// 导出对话历史
  List<Map<String, dynamic>> exportHistory() {
    return _messageHistory.map((msg) => msg.toJson()).toList();
  }

  /// 释放资源
  void dispose() {
    _streamController?.close();
    _engine.dispose();
    _messageHistory.clear();
  }
}
