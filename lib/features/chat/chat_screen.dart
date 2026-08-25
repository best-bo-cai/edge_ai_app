// lib/features/chat/chat_screen.dart
import 'package:flutter/material.dart';
import '../../core/services/chat_service.dart';
import '../../core/models/message.dart';
import '../../core/services/model_service.dart';

/// 聊天界面：llama.cpp 本地离线推理（流式输出）
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ChatService _chatService = ChatService();
  final ModelService _modelService = ModelService();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// 引擎状态：idle（未初始化）/loading（加载模型中）/ready/error
  String _engineState = 'idle';
  String? _engineError;
  bool _reloadScheduled = false;

  /// 模型加载进度（null = 无进度数据；加载中 0.0~1.0）
  double? _loadProgress;

  /// 生成期间收到模型切换事件时挂起重载，生成结束后执行
  bool _pendingReload = false;

  @override
  void initState() {
    super.initState();
    _ensureModelLoaded();
    // 模型切换/导入/删除事件驱动热重载。IndexedStack 常驻 + const 页面
    // 在切页时不 rebuild，build 里的 _maybeReload 兜底不可靠，须事件驱动
    _modelService.addListener(_onModelChanged);
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

  /// 加载当前选中模型（幂等；模型变化时自动热切换）
  Future<void> _ensureModelLoaded() async {
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
          _engineError = e.toString();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() {});
      // 生成期间收到模型切换事件 → 此刻生成已结束，补执行挂起的热重载
      if (_pendingReload && mounted && !_chatService.isGenerating) {
        _pendingReload = false;
        _ensureModelLoaded();
      }
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

  void _clearHistory() {
    _chatService.clearHistory();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _maybeReload();
    final noModel = _modelService.availableModels.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('LocalChat', style: TextStyle(fontSize: 18)),
            Text(
              _statusLine(),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _chatService.messageHistory.isNotEmpty ? _clearHistory : null,
            tooltip: '清除对话',
          ),
        ],
      ),
      body: Column(
        children: [
          // 引擎状态提示条
          if (_engineState == 'loading')
            _buildLoadingBanner()
          else if (_engineState == 'error')
            _buildStateBanner(
              icon: Icons.error_outline,
              color: Colors.red,
              text: _engineError ?? '模型加载失败',
              action: TextButton(onPressed: _ensureModelLoaded, child: const Text('重试')),
            ),

          if (noModel)
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
    final id = _modelService.currentModelId;
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
      color: Colors.blue.withValues(alpha: 0.08),
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
                    backgroundColor: Colors.blue.withValues(alpha: 0.12),
                  )
                : LinearProgressIndicator(
                    minHeight: 4,
                    backgroundColor: Colors.blue.withValues(alpha: 0.12),
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
      color: color.withValues(alpha: 0.08),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_download_outlined,
              size: 80,
              color: Colors.orange[400],
            ),
            const SizedBox(height: 24),
            const Text(
              '暂无可用模型',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              '请切换到底部"模型"标签页\n下载或导入 GGUF 模型后开始离线对话',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser ? Colors.blue : Colors.grey[200],
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.content.isEmpty && message.isStreaming ? '…' : message.content,
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

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
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
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
