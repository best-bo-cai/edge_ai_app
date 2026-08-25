// lib/core/services/chat_service.dart
import 'dart:async';

import '../engine/llama_engine.dart';
import '../models/message.dart';
import 'model_service.dart';

/// 聊天服务：管理对话历史与推理调度
///
/// 模型加载策略：
/// - ensureLoaded() 对比 ModelService 当前选中模型与引擎已加载路径，
///   不一致时自动热切换（卸载旧模型 → 加载新模型 → 清空历史）
/// - 无选中模型但本地已有模型时，自动选第一个
class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final LlamaEngine _engine = LlamaEngine.instance;
  final ModelService _modelService = ModelService();

  final List<ChatMessage> _messageHistory = [];

  /// 参与构建提示词的最大历史轮数（防止超出上下文窗口）
  static const int _maxHistoryMessages = 20;

  static const String _systemPrompt = 'You are a helpful AI assistant. Respond in Chinese.';

  bool _isGenerating = false;

  List<ChatMessage> get messageHistory => List.unmodifiable(_messageHistory);
  bool get isGenerating => _isGenerating;
  String get loadedModelDesc => _engine.modelDesc;
  String get loadedModelPath => _engine.loadedPath;

  /// 模型加载进度（0.0~1.0），仅加载期间有事件（供 UI 显示进度条）
  Stream<double> get loadProgress => _engine.loadProgress;

  /// 引擎当前加载的模型路径是否与 ModelService 选中的模型一致
  bool get isModelSynced {
    final current = _modelService.currentModelPath;
    return current != null && current == _engine.loadedPath;
  }

  /// 确保当前选中的模型已加载（幂等；模型变化时自动热切换）。
  /// 返回 null 表示就绪；否则返回错误信息。
  Future<String?> ensureLoaded() async {
    try {
      final initialized = await _engine.initialize();
      if (!initialized || _engine.isMock) return null; // Mock 模式始终"就绪"

      // 无选中模型但有本地模型 → 自动选第一个
      if (_modelService.currentModelId == null) {
        final models = _modelService.availableModels;
        if (models.isEmpty) return null;
        await _modelService.switchModel(models.first.id);
      }

      final targetPath = _modelService.currentModelPath;
      if (targetPath == null) return '未找到已下载的模型';

      if (_engine.isLoaded && _engine.loadedPath == targetPath) {
        return null; // 已加载且一致
      }

      // 热切换：卸载旧模型 + 清空历史
      _messageHistory.clear();
      await _engine.unload();

      final result = await _engine.loadModel(modelPath: targetPath);
      if (!result.ok) {
        return '模型加载失败：${result.error.isEmpty ? "未知错误" : result.error}';
      }
      return null;
    } catch (e) {
      // 引擎层异常兜底：转为错误信息，避免 UI 卡在 loading 态
      return '模型加载异常：$e';
    }
  }

  /// 模型被删除/切换后失效当前引擎状态（下一次 ensureLoaded 触发重载）
  void invalidate() {
    _messageHistory.clear();
  }

  /// 发送消息并获取流式回复
  Stream<String> sendMessage(String userMessage) async* {
    if (_isGenerating) {
      throw StateError('Already generating response');
    }
    _isGenerating = true;

    try {
      // 确保模型就绪（快速路径：已加载时为 no-op）
      final loadError = await ensureLoaded();
      if (loadError != null) {
        throw Exception(loadError);
      }

      _messageHistory.add(ChatMessage.user(userMessage));
      _messageHistory.add(ChatMessage.assistant('', isStreaming: true));

      try {
        // 构建含历史的完整提示词（原生模型模板优先，ChatML 兜底）
        yield* _streamWithHistoryUpdate(_engine.generate(_buildPrompt()));
      } on Exception catch (e) {
        // 上下文溢出：丢弃最旧一半历史后重试一次
        if (e.toString().contains('context window')) {
          _trimHistory(halve: true);
          yield* _streamWithHistoryUpdate(_engine.generate(_buildPrompt()));
        } else {
          rethrow;
        }
      }
    } finally {
      _finalizeStreamingMessage();
      _isGenerating = false;
    }
  }

  /// 中止当前生成（保留已生成的部分内容）
  void stopGeneration() {
    _engine.abort();
  }

  /// 流式转发并同步更新历史中的助手消息内容
  Stream<String> _streamWithHistoryUpdate(Stream<String> source) async* {
    String accumulated = '';
    await for (final token in source) {
      accumulated += token;
      final lastIndex = _messageHistory.length - 1;
      if (lastIndex >= 0) {
        _messageHistory[lastIndex] = _messageHistory[lastIndex].copyWith(
          content: accumulated,
        );
      }
      yield token;
    }
  }

  /// 结束占位消息的流式状态
  void _finalizeStreamingMessage() {
    if (_messageHistory.isEmpty) return;
    final last = _messageHistory.last;
    if (last.isStreaming) {
      _messageHistory[_messageHistory.length - 1] = last.copyWith(
        isStreaming: false,
        content: last.content,
      );
    }
  }

  /// 构建提示词：真实引擎走模型自带 ChatML/Jinja 模板，Mock/失败时 ChatML 兜底
  String _buildPrompt() {
    final window = _messageWindow();

    final native = _engine.applyChatTemplate([
      const TemplateMessage('system', _systemPrompt),
      ...window.map((m) => TemplateMessage(m.role.name, m.content)),
    ]);
    if (native != null && native.isNotEmpty) return native;

    // ChatML 兜底（覆盖 Qwen/DeepSeek 等 ChatML 系模型）
    final buffer = StringBuffer();
    buffer.writeln('<|im_start|>system');
    buffer.writeln(_systemPrompt);
    buffer.writeln('<|im_end|>');
    for (final msg in window) {
      buffer.writeln('<|im_start|>${msg.role.name}');
      buffer.writeln(msg.content);
      buffer.writeln('<|im_end|>');
    }
    buffer.write('<|im_start|>assistant\n');
    return buffer.toString();
  }

  /// 参与提示词的历史窗口（排除本轮 assistant 占位，限制条数防溢出）
  List<ChatMessage> _messageWindow() {
    final history = _messageHistory
        .where((m) => m.content.isNotEmpty)
        .toList(growable: false);
    if (history.length > _maxHistoryMessages) {
      return history.sublist(history.length - _maxHistoryMessages);
    }
    return history;
  }

  void _trimHistory({bool halve = false}) {
    // 保留末尾一半（至少 4 条）
    var keep = halve ? _messageHistory.length ~/ 2 : _maxHistoryMessages;
    if (keep < 4) keep = 4;
    if (_messageHistory.length > keep) {
      _messageHistory.removeRange(0, _messageHistory.length - keep);
    }
  }

  /// 清除对话历史
  void clearHistory() {
    _messageHistory.clear();
  }

  /// 释放资源（App 退出时）
  Future<void> dispose() async {
    await _engine.dispose();
    _messageHistory.clear();
  }
}
