// lib/features/chat/conversation_list_screen.dart
// 会话列表页（需求文档 §2.1）：按最后活跃时间倒序，支持切换/重命名/删除/新建
import 'package:flutter/material.dart';

import '../../core/services/conversation_service.dart';
import '../../core/services/model_service.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key});

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  final ConversationService _conversationService = ConversationService();
  final ModelService _modelService = ModelService();

  @override
  void initState() {
    super.initState();
    _conversationService.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openConversation(String id) async {
    await _conversationService.openConversation(id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _renameConversation(Conversation conv) async {
    final controller = TextEditingController(text: conv.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '会话标题'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('确定')),
        ],
      ),
    );
    if (title != null && title.trim().isNotEmpty) {
      await _conversationService.renameConversation(conv.id, title);
    }
  }

  Future<void> _deleteConversation(Conversation conv) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('「${conv.title}」及其全部消息将被永久删除，无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                '删除',
                style: TextStyle(color: Colors.red),
              )),
        ],
      ),
    );
    if (confirmed == true) {
      await _conversationService.deleteConversation(conv.id);
    }
  }

  Future<void> _newConversation() async {
    final modelId = _modelService.currentModelId ??
        (_modelService.availableModels.isNotEmpty
            ? _modelService.availableModels.first.id
            : null);
    if (modelId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无可用模型，请先下载或导入模型')),
        );
      }
      return;
    }
    await _conversationService.createConversation(modelId: modelId);
    if (mounted) Navigator.of(context).pop();
  }

  String _modelLabel(Conversation conv) {
    final info = _modelService.getModelInfo(conv.modelId);
    return info?.name ?? '模型已删除';
  }

  String _timeLabel(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final conversations = _conversationService.conversations;

    return Scaffold(
      appBar: AppBar(
        title: const Text('历史会话'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '新建会话',
            onPressed: _newConversation,
          ),
        ],
      ),
      body: conversations.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.forum_outlined, size: 72, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text('暂无历史会话', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
                  const SizedBox(height: 8),
                  Text('点击右上角新建会话', style: TextStyle(fontSize: 13, color: Colors.grey[500])),
                ],
              ),
            )
          : ListView.separated(
              itemCount: conversations.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
              itemBuilder: (context, index) {
                final conv = conversations[index];
                final isCurrent =
                    _conversationService.currentConversation?.id == conv.id;
                final modelMissing = _modelService.getModelInfo(conv.modelId) == null;

                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isCurrent ? Colors.blue : Colors.grey[300],
                    child: Icon(
                      isCurrent ? Icons.chat_bubble : Icons.chat_bubble_outline,
                      color: isCurrent ? Colors.white : Colors.grey[600],
                      size: 20,
                    ),
                  ),
                  title: Text(
                    conv.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    '${modelMissing ? '⚠ ' : ''}${_modelLabel(conv)} · ${conv.lastMessage.isEmpty ? '暂无消息' : conv.lastMessage}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: modelMissing ? Colors.orange[700] : Colors.grey[600],
                    ),
                  ),
                  trailing: Text(
                    _timeLabel(conv.updatedAt),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  onTap: () => _openConversation(conv.id),
                  onLongPress: () => _showActions(conv),
                );
              },
            ),
    );
  }

  void _showActions(Conversation conv) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _renameConversation(conv);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteConversation(conv);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _conversationService.removeListener(_onChanged);
    super.dispose();
  }
}
