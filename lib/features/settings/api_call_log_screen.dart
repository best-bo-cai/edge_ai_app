// lib/features/settings/api_call_log_screen.dart
// API 调用日志查看页（二期 §5.3 + 2026-08-30 grilling 决策）：
// - 入口：设置页「调用统计」卡片（整卡可点）
// - 列表：时间倒序，50 条/页滚动加载；条目含时间/端点/模型/token 数/状态码/来源 IP
// - 详情：完整请求与响应（JSON 美化，可复制）
// - 清空全部日志（确认对话框，无自动清理——决策 4）
// - 服务运行中新调用自动出现（监听 ApiServerService 通知重载）
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/services/api_server/api_server_service.dart';
import '../../core/services/app_database.dart';

class ApiCallLogScreen extends StatefulWidget {
  const ApiCallLogScreen({super.key});

  @override
  State<ApiCallLogScreen> createState() => _ApiCallLogScreenState();
}

class _ApiCallLogScreenState extends State<ApiCallLogScreen> {
  static const int _pageSize = 50;

  final ApiServerService _service = ApiServerService.instance;
  final ScrollController _scrollController = ScrollController();

  List<Map<String, Object?>> _logs = [];
  bool _loading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _scrollController.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 服务通知（新调用落库/统计刷新）→ 重载第一页，新调用自动出现
  void _onServiceChanged() {
    if (mounted) _reload();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 200 && !_loading && _hasMore) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final db = await AppDatabase().database;
      final rows = await db.query(
        'api_call_logs',
        orderBy: 'created_at DESC, id DESC',
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _logs = rows;
        _hasMore = rows.length == _pageSize;
      });
    } catch (_) {
      // DB 异常保持现有列表（下次通知重试）
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final db = await AppDatabase().database;
      final rows = await db.query(
        'api_call_logs',
        orderBy: 'created_at DESC, id DESC',
        limit: _pageSize,
        offset: _logs.length,
      );
      if (!mounted) return;
      setState(() {
        _logs.addAll(rows);
        _hasMore = rows.length == _pageSize;
      });
    } catch (_) {
      // 加载失败：保留已加载内容，用户滚动可重试
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部日志'),
        content: const Text('将删除所有 API 调用记录，调用统计一并归零。此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final db = await AppDatabase().database;
      await db.delete('api_call_logs');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('清空失败')),
        );
      }
      return;
    }
    await _service.refreshStats(); // 统计与日志同源归零（通知设置页刷新）
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('API 调用日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空全部日志',
            onPressed: _logs.isEmpty ? null : _clearAll,
          ),
        ],
      ),
      body: _logs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.receipt_long_outlined,
                      size: 48, color: theme.hintColor),
                  const SizedBox(height: 8),
                  Text('暂无调用记录',
                      style:
                          TextStyle(color: theme.hintColor)),
                ],
              ),
            )
          : ListView.builder(
              controller: _scrollController,
              itemCount: _logs.length + (_hasMore || _loading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _logs.length) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final row = _logs[index];
                return _LogTile(
                  row: row,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _LogDetailPage(row: row),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 列表条目：时间 / 状态码徽标 / 端点+模型 / token 数 + 来源 IP
class _LogTile extends StatelessWidget {
  final Map<String, Object?> row;
  final VoidCallback onTap;

  const _LogTile({required this.row, required this.onTap});

  static String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusCode = row['status_code'] as int?;
    final prompt = row['prompt_tokens'] as int?;
    final output = row['output_tokens'] as int?;
    final model = row['model_id'] as String?;
    final sourceIp = row['source_ip'] as String?;

    return ListTile(
      onTap: onTap,
      dense: true,
      leading: _StatusBadge(statusCode: statusCode),
      title: Text(
        row['endpoint'] as String? ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
      subtitle: Text(
        [
          _fmtTime(row['created_at'] as int),
          if (model != null) model,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        [
          if (prompt != null || output != null)
            '${prompt ?? '-'}→${output ?? '-'} tok',
          if (sourceIp != null && sourceIp.isNotEmpty) sourceIp,
        ].join('\n'),
        textAlign: TextAlign.end,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.hintColor, height: 1.4),
      ),
    );
  }
}

/// 状态码徽标：5xx 红 / 4xx 橙 / 2xx 绿 / 存量 NULL 灰"—"
class _StatusBadge extends StatelessWidget {
  final int? statusCode;

  const _StatusBadge({required this.statusCode});

  @override
  Widget build(BuildContext context) {
    final code = statusCode;
    final (text, fg, bg) = switch (code) {
      null => ('—', Colors.grey, Colors.grey.withValues(alpha: 0.15)),
      >= 500 => ('$code', Colors.red, Colors.red.withValues(alpha: 0.12)),
      >= 400 => (
        '$code',
        Colors.orange,
        Colors.orange.withValues(alpha: 0.12)
      ),
      _ => ('$code', Colors.green, Colors.green.withValues(alpha: 0.12)),
    };
    return Container(
      width: 42,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

/// 详情页：字段总览 + 完整请求/响应（JSON 美化，可复制）
class _LogDetailPage extends StatelessWidget {
  final Map<String, Object?> row;

  const _LogDetailPage({required this.row});

  static String _fmtTimeFull(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// JSON 美化；非 JSON（SSE 原文 / 占位文本）原样展示
  static String _pretty(String raw) {
    if (raw.isEmpty) return '(空)';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusCode = row['status_code'] as int?;

    return Scaffold(
      appBar: AppBar(title: const Text('调用详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _field(theme, '时间',
                  _fmtTimeFull(row['created_at'] as int)),
              _field(theme, '端点', row['endpoint'] as String? ?? '—'),
              _field(theme, '模型', row['model_id'] as String? ?? '—'),
              _field(theme, '状态码', statusCode?.toString() ?? '—（存量记录）'),
              _field(theme, 'Token',
                  '输入 ${row['prompt_tokens'] ?? '-'} / 输出 ${row['output_tokens'] ?? '-'}'),
              _field(theme, '来源 IP', row['source_ip'] as String? ?? '—'),
            ],
          ),
          const SizedBox(height: 16),
          _section(theme, '请求体'),
          _codeBlock(theme, _pretty(row['request_body'] as String? ?? '')),
          const SizedBox(height: 16),
          _section(theme, '响应体'),
          _codeBlock(theme, _pretty(row['response_body'] as String? ?? '')),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static Widget _field(ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
            TextSpan(
              text: value,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _section(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
      );

  static Widget _codeBlock(ThemeData theme, String content) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        content,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          height: 1.5,
        ),
      ),
    );
  }
}
