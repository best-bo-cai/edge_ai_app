// lib/core/services/chat_service.dart
import 'dart:async';

import '../engine/llama_engine.dart';
import '../models/message.dart';
import '../models/model_params.dart';
import 'conversation_service.dart';
import 'model_params_service.dart';
import 'model_service.dart';

/// 聊天服务：管理当前会话的消息时间线与推理调度
///
/// 模型加载策略（一期升级）：
/// - 目标模型 = 当前会话绑定的模型（会话切换/新建时由
///   ConversationService 同步到 ModelService，此处只读）
/// - 加载签名 = (模型路径, nCtx, nThreads)：参数配置改动 → 签名变化 → 自动重载
/// - 采样参数与 system prompt 每次生成从 ModelParamsService 读取（即时生效）
/// - 消息持久化经 ConversationService 落库（user 发送即写，
///   assistant 生成结束整体写）
class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final LlamaEngine _engine = LlamaEngine.instance;
  final ModelService _modelService = ModelService();
  final ModelParamsService _paramsService = ModelParamsService();
  final ConversationService _conversationService = ConversationService();

  /// UI 侧内存中的当前时间线（含流式占位消息；持久化由 ConversationService 负责）
  final List<ChatMessage> _messageHistory = [];

  /// 参与构建提示词的最大历史轮数（防止超出上下文窗口）
  static const int _maxHistoryMessages = 20;

  bool _isGenerating = false;

  List<ChatMessage> get messageHistory => List.unmodifiable(_messageHistory);
  bool get isGenerating => _isGenerating;
  String get loadedModelDesc => _engine.modelDesc;
  String get loadedModelPath => _engine.loadedPath;

  /// 模型加载进度（0.0~1.0），仅加载期间有事件（供 UI 显示进度条）
  Stream<double> get loadProgress => _engine.loadProgress;

  /// 当前会话绑定的模型 id（无会话时回退 ModelService 选中值）
  String? get targetModelId {
    final convModel = _conversationService.currentConversation?.modelId;
    if (convModel != null && _modelService.getModelInfo(convModel) != null) {
      return convModel;
    }
    return _modelService.currentModelId;
  }

  /// 引擎当前加载的模型路径是否与目标模型一致
  bool get isModelSynced {
    final id = targetModelId;
    if (id == null) return false;
    final info = _modelService.getModelInfo(id);
    return info != null && info.path == _engine.loadedPath;
  }

  /// 确保当前会话绑定的模型已加载（幂等；模型或上下文参数变化时自动热切换）。
  /// 返回 null 表示就绪；否则返回错误信息。
  Future<String?> ensureLoaded() async {
    try {
      final initialized = await _engine.initialize();
      if (!initialized || _engine.isMock) return null; // Mock 模式始终"就绪"

      final targetId = targetModelId;
      if (targetId == null) {
        // 无会话/无选中模型但有本地模型 → 自动选第一个（触发会话创建链路）
        if (_modelService.currentModelId == null &&
            _modelService.availableModels.isNotEmpty) {
          await _modelService.switchModel(_modelService.availableModels.first.id);
        }
        final id2 = targetModelId;
        if (id2 == null) return null;
        return await _loadModelFor(id2);
      }
      return await _loadModelFor(targetId);
    } catch (e) {
      // 引擎层异常兜底：转为错误信息，避免 UI 卡在 loading 态
      return '模型加载异常：$e';
    }
  }

  Future<String?> _loadModelFor(String modelId) async {
    final info = _modelService.getModelInfo(modelId);
    if (info == null) return '会话绑定的模型已被删除，请重新选择模型';
    final params = await _paramsService.getParams(modelId);

    // 签名一致（路径 + nCtx/nThreads）→ 已就绪
    if (_engine.isLoaded &&
        _engine.loadedPath == info.path &&
        _signatureOf(info.path, params) == _lastSignature) {
      return null;
    }

    // 热切换：卸载旧模型（时间线由会话层持有，此处不清空）
    await _engine.unload();
    _lastSignature = _signatureOf(info.path, params);

    final result = await _engine.loadModel(
      modelPath: info.path,
      nCtx: params.nCtx,
      nThreads: params.nThreads,
    );
    if (!result.ok) {
      _lastSignature = null;
      return '模型加载失败：${result.error.isEmpty ? "未知错误" : result.error}';
    }
    return null;
  }

  /// 加载签名：上下文参数参与判断（参数配置改动 → 强制重载，需求文档 §4.2）
  (String, int, int)? _lastSignature;
  (String, int, int) _signatureOf(String path, ModelParams params) =>
      (path, params.nCtx, params.nThreads);

  /// 模型被删除/切换后失效当前引擎状态（下一次 ensureLoaded 触发重载）
  void invalidate() {
    _messageHistory.clear();
    _lastSignature = null;
  }

  /// 会话切换后同步内存时间线（丢弃流式中间态，直接用持久化数据）
  void syncTimelineFromConversation() {
    _messageHistory
      ..clear()
      ..addAll(_conversationService.currentMessages);
    _lastSignature = null; // 目标模型可能变化，确保 ensureLoaded 重新校验
  }

  /// 发送消息并获取流式回复
  Stream<String> sendMessage(String userMessage) async* {
    if (_isGenerating) {
      throw StateError('Already generating response');
    }
    _isGenerating = true;

    // 捕获本次生成所属会话：生成中用户切换会话时，消息仍写回原会话
    final conversationId = _conversationService.currentConversation?.id;

    try {
      // 确保模型就绪（快速路径：已加载且签名一致时为 no-op）
      final loadError = await ensureLoaded();
      if (loadError != null) {
        throw Exception(loadError);
      }

      if (conversationId == null) {
        throw Exception('当前无会话');
      }

      // user 消息：落库 + 上屏（需求文档 §2.2：发送时即落库）
      await _conversationService.appendUserMessage(userMessage,
          conversationId: conversationId);
      _messageHistory.add(ChatMessage.user(userMessage));
      _messageHistory.add(ChatMessage.assistant('', isStreaming: true));

      final params = _paramsService.paramsOf(targetModelId ?? '');

      try {
        yield* _streamWithHistoryUpdate(_engine.generate(
          _buildPrompt(params.systemPrompt),
          maxTokens: params.maxTokens,
          topK: params.topK.toDouble(),
          topP: params.topP,
          temperature: params.temperature,
          repeatPenalty: params.repeatPenalty,
        ));
      } on Exception catch (e) {
        // 上下文溢出：丢弃最旧一半历史后重试一次
        if (e.toString().contains('context window')) {
          _trimHistory(halve: true);
          yield* _streamWithHistoryUpdate(_engine.generate(
            _buildPrompt(params.systemPrompt),
            maxTokens: params.maxTokens,
            topK: params.topK.toDouble(),
            topP: params.topP,
            temperature: params.temperature,
            repeatPenalty: params.repeatPenalty,
          ));
        } else {
          rethrow;
        }
      }
    } finally {
      _finalizeStreamingMessage();
      // assistant 消息整体落库（含中止时的部分内容，需求文档 §2.2）
      final last = _messageHistory.isEmpty ? null : _messageHistory.last;
      if (last != null && last.role == MessageRole.assistant && last.content.isNotEmpty) {
        await _conversationService.appendAssistantMessage(last.content,
            conversationId: conversationId);
      }
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

  /// 构建提示词：真实引擎走模型自带 ChatML/Jinja 模板，Mock/失败时 ChatML 兜底。
  /// system prompt 来自每模型配置（需求文档 §4.1）
  String _buildPrompt(String systemPrompt) {
    final window = _messageWindow();

    final native = _engine.applyChatTemplate([
      TemplateMessage('system', systemPrompt),
      ...window.map((m) => TemplateMessage(m.role.name, m.content)),
    ]);
    if (native != null && native.isNotEmpty) return native;

    // ChatML 兜底（覆盖 Qwen/DeepSeek 等 ChatML 系模型）
    final buffer = StringBuffer();
    buffer.writeln('<|im_start|>system');
    buffer.writeln(systemPrompt);
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

  /// 清除当前会话时间线（新会话/切换会话时由 UI 调用 syncTimeline 代替）
  void clearHistory() {
    _messageHistory.clear();
  }

  /// 释放资源（App 退出时）
  Future<void> dispose() async {
    await _engine.dispose();
    _messageHistory.clear();
  }
}
