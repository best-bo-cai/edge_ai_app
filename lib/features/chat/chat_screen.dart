// lib/features/chat/chat_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/services/chat_service.dart';
import '../../core/services/conversation_service.dart';
import '../../core/models/message.dart';
import '../../core/services/model_params_service.dart';
import '../../core/services/model_service.dart';
import '../settings/model_params_screen.dart';
import 'conversation_list_screen.dart';

/// 聊天界面：llama.cpp 本地离线推理（流式输出）+ 多会话（一期）
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ChatService _chatService = ChatService();
  final ConversationService _conversationService = ConversationService();
  final ModelService _modelService = ModelService();
  final ModelParamsService _paramsService = ModelParamsService();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// 引擎状态：idle（未初始化）/loading（加载模型中）/ready/error
  String _engineState = 'idle';
  String? _engineError;
  bool _reloadScheduled = false;

  /// 模型加载进度（null = 无进度数据；加载中 0.0~1.0）
  double? _loadProgress;

  /// 生成期间收到模型切换/参数变更事件时挂起重载，生成结束后执行
  bool _pendingReload = false;

  @override
  void initState() {
    super.initState();
    // 冷启动：会话已在 main() 中恢复，但此时本页 listener 尚未注册，
    // 须主动同步一次时间线（否则历史消息不显示）
    _chatService.syncTimelineFromConversation();
    _ensureModelLoaded();
    // 模型切换/导入/删除事件驱动热重载。IndexedStack 常驻 + const 页面
    // 在切页时不 rebuild，build 里的 _maybeReload 兜底不可靠，须事件驱动
    _modelService.addListener(_onModelChanged);
    // 会话切换（列表页点开旧会话/新建/删除）→ 时间线同步 + 目标模型校验
    _conversationService.addListener(_onConversationChanged);
    // 参数配置变更（n_ctx/n_threads）→ 签名变化触发按需重载
    _paramsService.addListener(_onParamsChanged);
    // 加载进度（0~1）驱动进度条；非加载期间无事件，不干扰 UI
    _chatService.loadProgress.listen((p) {
      if (mounted && _engineState == 'loading') {
        setState(() => _loadProgress = p);
      }
    });
  }

  void _onModelChanged() {
    if (!mounted) return;
    if (_chatService.isGenerating) {
      _pendingReload = true; // 生成中不打断，结束后补载
      return;
    }
    _ensureModelLoaded();
  }

  /// 会话切换：同步内存时间线，确保新会话绑定的模型被加载。
  /// 生成中切换会话（列表页操作）：不打断生成也不清流式时间线，
  /// 挂起到生成结束后再同步（生成内容仍写回原会话，由 ChatService 保证）
  void _onConversationChanged() {
    if (!mounted) return;
    if (_chatService.isGenerating) {
      _pendingReload = true;
      return;
    }
    _chatService.syncTimelineFromConversation();
    setState(() {}); // 时间线立即刷新
    _ensureModelLoaded();
  }

  /// 参数配置变更：上下文参数（n_ctx/n_threads）签名变化时引擎自动重载
  void _onParamsChanged() {
    if (!mounted) return;
    if (_chatService.isGenerating) {
      _pendingReload = true;
      return;
    }
    _ensureModelLoaded();
  }

  /// 加载当前会话绑定的模型（幂等；模型/上下文参数变化时自动热切换）
  Future<void> _ensureModelLoaded() async {
    if (_conversationService.currentModelMissing) {
      setState(() => _engineState = 'idle');
      return;
    }
    if (_modelService.availableModels.isEmpty) {
      setState(() => _engineState = 'idle');
      return;
    }
    if (_engineState != 'loading') {
      setState(() {
        _engineState = 'loading';
        _engineError = null;
        _loadProgress = null;
      });
    }
    try {
      final error = await _chatService.ensureLoaded();
      if (!mounted) return;
      setState(() {
        _engineState = error == null ? 'ready' : 'error';
        _engineError = error;
      });
    } catch (e) {
      // 兜底：引擎层异常不应让 UI 卡在 loading 态
      if (!mounted) return;
      setState(() {
        _engineState = 'error';
        _engineError = '模型加载异常：$e';
      });
    }
  }

  /// build 时检测模型选择是否变化（IndexedStack 常驻，切页回来自动重载）
  void _maybeReload() {
    if (_reloadScheduled || _chatService.isGenerating) return;
    if (_engineState == 'loading') return;
    final hasModel = _modelService.availableModels.isNotEmpty;
    final synced = _chatService.isModelSynced || _chatService.loadedModelPath.isEmpty;
    if (hasModel && !synced) {
      _reloadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _reloadScheduled = false;
        if (mounted) _ensureModelLoaded();
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _chatService.isGenerating) return;

    // 会话绑定模型已删除 → 引导选择替代模型（决策 2 边界场景）
    if (_conversationService.currentModelMissing) {
      await _promptRebindModel();
      return;
    }
    // 无当前会话（首启）→ 自动创建
    if (_conversationService.currentConversation == null) {
      final modelId = _modelService.currentModelId ??
          (_modelService.availableModels.isNotEmpty
              ? _modelService.availableModels.first.id
              : null);
      if (modelId == null) return;
      await _conversationService.createConversation(modelId: modelId);
    }

    _inputController.clear();

    try {
      final stream = _chatService.sendMessage(text);
      setState(() {}); // 用户消息上屏

      await for (final _ in stream) {
        if (mounted) setState(() {}); // 流式更新
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _engineState = 'error';
          _engineError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() {});
      // 生成期间收到模型切换/会话切换/参数变更事件 → 此刻生成已结束，
      // 补同步时间线与热重载
      if (_pendingReload && mounted && !_chatService.isGenerating) {
        _pendingReload = false;
        _chatService.syncTimelineFromConversation();
        setState(() {});
        _ensureModelLoaded();
      }
    }
  }

  /// 模型缺失时弹窗选择替代模型并重绑当前会话
  Future<void> _promptRebindModel() async {
    final models = _modelService.availableModels;
    if (models.isEmpty) {
      setState(() => _engineState = 'idle');
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('模型已删除'),
        content: const Text('当前会话绑定的模型已被删除，请选择替代模型继续对话：'),
        actions: models
            .map((m) => TextButton(
                  onPressed: () => Navigator.pop(ctx, m.id),
                  child: Text(m.name, style: const TextStyle(fontSize: 13)),
                ))
            .toList(),
      ),
    );
    if (selected != null && mounted) {
      await _conversationService.rebindConversation(
          _conversationService.currentConversation!.id, selected);
    }
  }

  void _stopGeneration() {
    _chatService.stopGeneration();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _openConversationList() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ConversationListScreen()),
    );
  }

  /// 模型参数配置页（当前会话绑定模型的参数；保存后采样参数即时生效，
  /// n_ctx/n_threads 变化经 ModelParamsService 广播自动重载）
  void _openModelParams() {
    final modelId = _chatService.targetModelId ?? _modelService.currentModelId;
    if (modelId == null) return;
    final info = _modelService.getModelInfo(modelId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ModelParamsScreen(
          modelId: modelId,
          modelName: info?.name ?? modelId,
        ),
      ),
    );
  }

  Future<void> _newConversation() async {
    final modelId = _modelService.currentModelId ??
        (_modelService.availableModels.isNotEmpty
            ? _modelService.availableModels.first.id
            : null);
    if (modelId == null) return;
    await _conversationService.createConversation(modelId: modelId);
  }

  @override
  Widget build(BuildContext context) {
    _maybeReload();
    final noModel = _modelService.availableModels.isEmpty;
    final modelMissing = _conversationService.currentModelMissing;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _conversationService.currentConversation?.title ?? 'LocalChat',
              style: const TextStyle(fontSize: 18),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _statusLine(),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            onPressed: noModel ? null : _openModelParams,
            tooltip: '模型参数',
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: noModel ? null : _newConversation,
            tooltip: '新建会话',
          ),
        ],
        leading: IconButton(
          icon: const Icon(Icons.history),
          onPressed: _openConversationList,
          tooltip: '历史会话',
        ),
      ),
      body: Column(
        children: [
          // 引擎状态提示条
          if (_engineState == 'loading')
            _buildLoadingBanner()
          else if (modelMissing)
            _buildStateBanner(
              icon: Icons.warning_amber_rounded,
              color: Colors.orange,
              text: '会话绑定的模型已被删除',
              action: TextButton(
                onPressed: _promptRebindModel,
                child: const Text('选择替代模型'),
              ),
            )
          else if (_engineState == 'error')
            _buildStateBanner(
              icon: Icons.error_outline,
              color: Colors.red,
              text: _engineError ?? '模型加载失败',
              action: TextButton(onPressed: _ensureModelLoaded, child: const Text('重试')),
            ),

          if (noModel || modelMissing)
            Expanded(child: _buildNoModelWarning())
          else
            Expanded(child: _buildMessageList()),

          _buildInputArea(),
        ],
      ),
    );
  }

  String _statusLine() {
    if (_modelService.availableModels.isEmpty) return '未加载模型';
    final desc = _chatService.loadedModelDesc;
    final name = _currentModelName();
    if (desc.isNotEmpty && desc != 'Mock Engine') return desc;
    return name ?? '未加载模型';
  }

  String? _currentModelName() {
    final id = _chatService.targetModelId ?? _modelService.currentModelId;
    if (id != null) {
      final info = _modelService.getModelInfo(id);
      if (info != null) return info.name;
    }
    final models = _modelService.availableModels;
    return models.isNotEmpty ? models.first.name : null;
  }

  /// 加载中提示条：进度条 + 百分比。
  /// 进度来源 llama.cpp 加载回调（读模型文件阶段）；null 表示尚无进度数据
  /// （如 mmap 快速映射或上下文初始化阶段），显示不确定进度动画。
  Widget _buildLoadingBanner() {
    final p = _loadProgress ?? 0.0;
    final hasProgress = p > 0;
    // 模型文件已读完（>=1.0）→ 剩余为上下文/KV 缓存初始化阶段
    final text = hasProgress
        ? (p >= 1.0
            ? '正在初始化推理上下文…'
            : '正在加载模型 ${(p * 100).toInt()}%')
        : '正在加载模型…';
    return Container(
      width: double.infinity,
      color: Colors.blue.withOpacity(0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hourglass_top, size: 16, color: Colors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text,
                    style: const TextStyle(fontSize: 12, color: Colors.blue),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 4,
            child: hasProgress
                ? LinearProgressIndicator(
                    value: p.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: Colors.blue.withOpacity(0.12),
                  )
                : LinearProgressIndicator(
                    minHeight: 4,
                    backgroundColor: Colors.blue.withOpacity(0.12),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStateBanner({
    required IconData icon,
    required Color color,
    required String text,
    Widget? action,
  }) {
    return Container(
      width: double.infinity,
      color: color.withOpacity(0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, color: color),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
          if (action != null) action,
        ],
      ),
    );
  }

  /// 构建无模型警告
  Widget _buildNoModelWarning() {
    final modelMissing = _conversationService.currentModelMissing;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              modelMissing ? Icons.warning_amber_rounded : Icons.cloud_download_outlined,
              size: 80,
              color: modelMissing ? Colors.orange[400] : Colors.orange[400],
            ),
            const SizedBox(height: 24),
            Text(
              modelMissing ? '会话绑定的模型已删除' : '暂无可用模型',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              modelMissing
                  ? '点击上方「选择替代模型」继续对话'
                  : '请切换到底部"模型"标签页\n下载或导入 GGUF 模型后开始离线对话',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList() {
    final messages = _chatService.messageHistory;

    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 80,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              '开始与 AI 对话吧！',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '完全离线 · 隐私安全 · 零流量消耗',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return _buildMessageBubble(message);
      },
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final isUser = message.role == MessageRole.user;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              backgroundColor: Colors.blue[100],
              child: const Icon(Icons.smart_toy, color: Colors.blue),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              // 四期 §3：仅 assistant 气泡长按弹复制菜单（复制正文，不含思考）
              onLongPressStart: isUser
                  ? null
                  : (_) => _showCopyMenu(message),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isUser ? Colors.blue : Colors.grey[200],
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 思考内容折叠区（四期 §4：生成中展开，完成后收起）
                    if (!isUser && message.reasoning.isNotEmpty)
                      _ThinkBlock(message: message),
                    Text(
                      message.content.isEmpty && message.isStreaming
                          ? (message.reasoning.isEmpty ? '…' : '')
                          : message.content,
                      style: TextStyle(
                        color: isUser ? Colors.white : Colors.black87,
                        fontSize: 16,
                        height: 1.5,
                      ),
                    ),
                    if (message.isStreaming) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isUser ? Colors.white : Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              backgroundColor: Colors.green[100],
              child: const Icon(Icons.person, color: Colors.green),
            ),
          ],
        ],
      ),
    );
  }

  /// assistant 气泡长按菜单（四期 §3.1：复制正文；正文为空时置灰）
  void _showCopyMenu(ChatMessage message) {
    final canCopy = message.content.trim().isNotEmpty;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制正文'),
              subtitle: message.reasoning.isEmpty
                  ? null
                  : const Text('不含思考内容', style: TextStyle(fontSize: 12)),
              enabled: canCopy,
              onTap: canCopy
                  ? () {
                      Clipboard.setData(
                          ClipboardData(text: message.content));
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('已复制'),
                            duration: Duration(seconds: 1)),
                      );
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                decoration: InputDecoration(
                  hintText: '输入消息...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: const BorderSide(color: Colors.blue),
                  ),
                ),
                maxLines: 1,
                onSubmitted: (_) => _sendMessage(),
                enabled: !_chatService.isGenerating,
              ),
            ),
            const SizedBox(width: 12),
            CircleAvatar(
              backgroundColor: _chatService.isGenerating ? Colors.red : Colors.blue,
              child: IconButton(
                icon: Icon(
                  _chatService.isGenerating ? Icons.stop : Icons.send,
                  color: Colors.white,
                ),
                onPressed: _chatService.isGenerating ? _stopGeneration : _sendMessage,
                tooltip: _chatService.isGenerating ? '停止生成' : '发送',
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _modelService.removeListener(_onModelChanged);
    _conversationService.removeListener(_onConversationChanged);
    _paramsService.removeListener(_onParamsChanged);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

/// 思考内容折叠块（四期 §4）：
/// - 生成中（isStreaming）：默认展开，标题显示「思考中…」
/// - 生成完成：自动收起，标题「已深度思考」，点击切换展开/收起
/// - 折叠状态仅存 UI 内存，不持久化（重进会话恢复默认收起）
class _ThinkBlock extends StatefulWidget {
  final ChatMessage message;
  const _ThinkBlock({required this.message});

  @override
  State<_ThinkBlock> createState() => _ThinkBlockState();
}

class _ThinkBlockState extends State<_ThinkBlock> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _ThinkBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 生成结束 → 自动收起（需求 §4.1：完成后自动收起，点开可回看）
    if (oldWidget.message.isStreaming && !widget.message.isStreaming) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final streaming = message.isStreaming;
    // 生成中默认展开：streaming 态视为展开（用户无需点击）
    final expanded = streaming || _expanded;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行：点击切换（生成中点击无效果，始终展开）
          InkWell(
            onTap: streaming ? null : _toggle,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.psychology,
                    size: 14,
                    color: Colors.blueGrey[400],
                  ),
                  const SizedBox(width: 4),
                  Text(
                    streaming ? '思考中…' : '已深度思考',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blueGrey[400],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (!streaming)
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 14,
                      color: Colors.blueGrey[400],
                    ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, top: 2),
              child: Text(
                message.reasoning,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: Colors.blueGrey[600],
                ),
              ),
            ),
          // 思考区与正文之间的分隔线（仅完成态显示，避免生成中视觉噪音）
          if (!streaming)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Divider(
                height: 1,
                color: Colors.blueGrey[100],
              ),
            ),
        ],
      ),
    );
  }

  void _toggle() => setState(() => _expanded = !_expanded);
}
