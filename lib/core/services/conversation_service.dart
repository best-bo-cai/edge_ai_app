// lib/core/services/conversation_service.dart
// 会话服务：多会话 CRUD、当前会话切换、模型切换联动（需求文档 §2/§3）
//
// 联动规则（grilling 决策 1/2）：
// - 会话创建时绑定模型；点开旧会话自动热切回其绑定模型
// - 用户主动切换模型（ModelService 广播）→ 当前会话归档，自动创建新会话
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/message.dart';
import 'app_database.dart';
import 'model_service.dart';

/// 会话（词汇表见 CONTEXT.md）
class Conversation {
  final String id;
  String title;
  String modelId;
  final DateTime createdAt;
  DateTime updatedAt;
  String lastMessage;

  Conversation({
    required this.id,
    required this.title,
    required this.modelId,
    required this.createdAt,
    required this.updatedAt,
    this.lastMessage = '',
  });

  factory Conversation.fromRow(Map<String, dynamic> row) => Conversation(
        id: row['id'] as String,
        title: row['title'] as String,
        modelId: row['model_id'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
        lastMessage: row['last_message'] as String? ?? '',
      );
}

/// 会话服务（ChangeNotifier）：
/// - 会话列表/当前会话/当前消息时间线，变化时广播（UI 与 ChatService 监听）
/// - 监听 ModelService：模型切换 → 归档当前会话 + 新会话绑定新模型（需求 2）
class ConversationService extends ChangeNotifier {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  static const String _prefCurrentId = 'current_conversation_id';

  final ModelService _modelService = ModelService();

  List<Conversation> _conversations = [];
  Conversation? _current;
  List<ChatMessage> _currentMessages = [];
  bool _initialized = false;

  /// 消息分页大小（需求文档 §2.3：每页 50 条）
  static const int pageSize = 50;

  /// 消息时间线全量计数（判断是否还有更早消息可加载）
  int _totalMessages = 0;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  Conversation? get currentConversation => _current;
  List<ChatMessage> get currentMessages => List.unmodifiable(_currentMessages);
  bool get hasMoreMessages => _currentMessages.length < _totalMessages;

  /// 生成唯一 id：毫秒时间戳 + 进程内自增序列（同一毫秒多条不冲突）
  static int _seq = 0;
  static String _newId(String prefix) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return '$prefix-$now-${_seq++}';
  }

  /// 初始化：加载会话列表，恢复上次活跃会话（需求文档 §2.3）
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final db = await AppDatabase().database;
    final rows = await db.query('conversations',
        orderBy: 'updated_at DESC');
    _conversations = rows.map(Conversation.fromRow).toList();

    // 恢复最后活跃会话
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getString(_prefCurrentId);
    if (lastId != null && _conversations.any((c) => c.id == lastId)) {
      await _openConversationInternal(lastId, syncModel: true);
    }

    // 模型切换 → 归档当前会话 + 开新会话（需求 2）
    _modelService.addListener(_onModelSwitched);
  }

  /// ModelService 广播处理：
  /// - 打开旧会话引发的同步（modelId == 当前会话绑定）→ 忽略
  /// - 真正的模型切换 → 当前会话归档，创建绑定新模型的新会话
  void _onModelSwitched() {
    final modelId = _modelService.currentModelId;
    if (modelId == null) return;
    if (_current != null && _current!.modelId == modelId) return;

    // 无会话（首启/模型刚就绪）→ 只建新会话，无需归档
    // 无可用模型不建（保持空态引导页）
    if (_modelService.availableModels.isEmpty) return;

    unawaited(createConversation(modelId: modelId));
  }

  /// 创建新会话并设为当前。需求 3：切换模型后自动调用；
  /// 手动"新建会话"复用：若当前会话为空（无消息）则直接复用当前会话
  /// 并重绑模型（避免堆积空会话）。
  Future<Conversation> createConversation({
    required String modelId,
    bool reuseEmptyCurrent = true,
  }) async {
    if (reuseEmptyCurrent && _current != null && _currentMessages.isEmpty) {
      if (_current!.modelId != modelId) {
        await rebindConversation(_current!.id, modelId);
      }
      return _current!;
    }

    final conv = Conversation(
      id: _newId('conv'),
      title: '新对话',
      modelId: modelId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final db = await AppDatabase().database;
    await db.insert('conversations', {
      'id': conv.id,
      'title': conv.title,
      'model_id': conv.modelId,
      'created_at': conv.createdAt.millisecondsSinceEpoch,
      'updated_at': conv.updatedAt.millisecondsSinceEpoch,
      'last_message': '',
    });

    _conversations.insert(0, conv);
    await _setCurrent(conv, syncModel: true);
    return conv;
  }

  /// 打开会话：加载消息时间线，同步引擎目标模型（决策 2：会话绑模型，自动切）
  Future<void> openConversation(String conversationId) async {
    await _openConversationInternal(conversationId, syncModel: true);
    notifyListeners();
  }

  Future<void> _openConversationInternal(
    String conversationId, {
    required bool syncModel,
  }) async {
    final conv = _conversations.firstWhere(
      (c) => c.id == conversationId,
      orElse: () => throw Exception('会话不存在'),
    );
    await _setCurrent(conv, syncModel: syncModel);
  }

  Future<void> _setCurrent(Conversation conv, {required bool syncModel}) async {
    _current = conv;
    await _loadMessages();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefCurrentId, conv.id);

    // 会话绑定模型 → 同步为当前选中模型（触发引擎热切换链路）。
    // 该同步引发的 ModelService 广播会被 _onModelSwitched 忽略（modelId 一致）
    if (syncModel &&
        conv.modelId != _modelService.currentModelId &&
        _modelService.getModelInfo(conv.modelId) != null) {
      await _modelService.switchModel(conv.modelId);
    }
  }

  /// 加载最近一页消息（时间线尾部，对话所需）
  Future<void> _loadMessages() async {
    final conv = _current;
    if (conv == null) {
      _currentMessages = [];
      _totalMessages = 0;
      return;
    }
    final db = await AppDatabase().database;
    final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM messages WHERE conversation_id = ?', [conv.id]);
    _totalMessages = Sqflite.firstIntValue(countRows) ?? 0;

    final rows = await db.query('messages',
        where: 'conversation_id = ?',
        whereArgs: [conv.id],
        orderBy: 'created_at DESC',
        limit: pageSize);
    _currentMessages = rows
        .reversed
        .map((r) => ChatMessage.splitLegacy(ChatMessage(
              id: r['id'] as String,
              role: MessageRole.values.firstWhere((e) => e.name == r['role']),
              content: r['content'] as String,
              timestamp: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
              reasoning: r['reasoning'] as String? ?? '',
            )))
        .toList();
  }

  /// 加载更早的一页消息（列表顶部"加载更早"）
  Future<void> loadEarlierMessages() async {
    final conv = _current;
    if (conv == null || !hasMoreMessages) return;
    final db = await AppDatabase().database;
    final earliest = _currentMessages.isEmpty
        ? DateTime.now().millisecondsSinceEpoch
        : _currentMessages.first.timestamp.millisecondsSinceEpoch;
    final rows = await db.query('messages',
        where: 'conversation_id = ? AND created_at < ?',
        whereArgs: [conv.id, earliest],
        orderBy: 'created_at DESC',
        limit: pageSize);
    final earlier = rows
        .reversed
        .map((r) => ChatMessage.splitLegacy(ChatMessage(
              id: r['id'] as String,
              role: MessageRole.values.firstWhere((e) => e.name == r['role']),
              content: r['content'] as String,
              timestamp: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
              reasoning: r['reasoning'] as String? ?? '',
            )))
        .toList();
    _currentMessages = [...earlier, ..._currentMessages];
    notifyListeners();
  }

  /// 重命名会话
  Future<void> renameConversation(String conversationId, String title) async {
    final conv = _conversations.firstWhere((c) => c.id == conversationId);
    conv.title = title.trim().isEmpty ? conv.title : title.trim();
    final db = await AppDatabase().database;
    await db.update('conversations', {'title': conv.title},
        where: 'id = ?', whereArgs: [conversationId]);
    notifyListeners();
  }

  /// 重绑模型（模型缺失后的替代选择，决策 2 边界场景）
  Future<void> rebindConversation(String conversationId, String modelId) async {
    final conv = _conversations.firstWhere((c) => c.id == conversationId);
    conv.modelId = modelId;
    final db = await AppDatabase().database;
    await db.update('conversations', {'model_id': modelId},
        where: 'id = ?', whereArgs: [conversationId]);

    // 重绑的是当前会话 → 同步引擎目标模型
    if (_current?.id == conversationId && _modelService.getModelInfo(modelId) != null) {
      await _modelService.switchModel(modelId);
    }
    notifyListeners();
  }

  /// 删除会话及其全部消息（物理删除，需求文档 §2.1）
  Future<void> deleteConversation(String conversationId) async {
    final db = await AppDatabase().database;
    await db.delete('messages',
        where: 'conversation_id = ?', whereArgs: [conversationId]);
    await db.delete('conversations',
        where: 'id = ?', whereArgs: [conversationId]);

    _conversations.removeWhere((c) => c.id == conversationId);

    if (_current?.id == conversationId) {
      _current = null;
      _currentMessages = [];
      _totalMessages = 0;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefCurrentId);
      // 删除当前会话后：若仍有模型，切到最近活跃的其他会话；否则保持空态
      if (_conversations.isNotEmpty) {
        await _openConversationInternal(_conversations.first.id, syncModel: true);
      }
    }
    notifyListeners();
  }

  // ---------- ChatService 写入接口 ----------

  /// 追加用户消息（发送时即落库，需求文档 §2.2）。
  /// conversationId 指定写入的会话（生成中用户切换会话时消息仍归原会话）
  Future<void> appendUserMessage(String content, {String? conversationId}) async {
    final conv = _targetConversation(conversationId);
    if (conv == null) return;
    final msg = ChatMessage.user(content);
    await _insertMessage(conv, msg);
    if (_current?.id == conv.id) {
      _currentMessages = [..._currentMessages, msg];
    }
    await _updateSummary(conv, content);
    notifyListeners();
  }

  /// 追加助手消息（生成结束/中止时整体落库，需求文档 §2.2/§2.4）
  Future<void> appendAssistantMessage(String content,
      {String? conversationId, String reasoning = ''}) async {
    final conv = _targetConversation(conversationId);
    if (conv == null || (content.isEmpty && reasoning.isEmpty)) return;
    final msg = ChatMessage.assistant(content, reasoning: reasoning);
    await _insertMessage(conv, msg);
    if (_current?.id == conv.id) {
      _currentMessages = [..._currentMessages, msg];
    }
    await _updateSummary(conv, content.isEmpty ? reasoning : content);
    notifyListeners();
  }

  Conversation? _targetConversation(String? conversationId) {
    if (conversationId != null) {
      for (final c in _conversations) {
        if (c.id == conversationId) return c;
      }
      return null; // 会话已被删除：消息丢弃
    }
    return _current;
  }

  Future<void> _insertMessage(Conversation conv, ChatMessage msg) async {
    final db = await AppDatabase().database;
    await db.insert('messages', {
      'id': _newId('msg'),
      'conversation_id': conv.id,
      'role': msg.role.name,
      'content': msg.content,
      // 四期 §2.4：思考内容独立落库（旧版混合存储由读取侧懒拆分兜底）
      if (msg.reasoning.isNotEmpty) 'reasoning': msg.reasoning,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 更新会话摘要与最后活跃时间；首条用户消息自动生成标题（§2.1）
  Future<void> _updateSummary(Conversation conv, String content) async {
    conv.updatedAt = DateTime.now();
    conv.lastMessage = content;
    if (conv.title == '新对话' && content.trim().isNotEmpty) {
      final t = content.trim();
      conv.title = t.length > 20 ? t.substring(0, 20) : t;
    }
    final db = await AppDatabase().database;
    await db.update(
        'conversations',
        {
          'updated_at': conv.updatedAt.millisecondsSinceEpoch,
          'last_message': _summaryOf(conv.lastMessage),
          'title': conv.title,
        },
        where: 'id = ?',
        whereArgs: [conv.id]);
    // 列表按最后活跃时间排序：移到最前
    _conversations.remove(conv);
    _conversations.insert(0, conv);
  }

  String _summaryOf(String content) =>
      content.length > 60 ? content.substring(0, 60) : content;

  /// 当前会话绑定的模型是否已被删除（决策 2 边界：提示选择替代模型）
  bool get currentModelMissing =>
      _current != null && _modelService.getModelInfo(_current!.modelId) == null;
}
