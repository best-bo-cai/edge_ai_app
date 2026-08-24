// lib/features/model_market/widgets/download_button.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/services/download_manager.dart';

/// 单文件下载按钮：下载 → 进度+速度+暂停 → 校验中 → 完成(加载运行)
/// 暂停 → 继续/取消；失败 → 重试（需求 2.4）
class DownloadButton extends StatefulWidget {
  const DownloadButton({
    super.key,
    required this.savePath,
    required this.onStart,
    required this.onRun,
  });

  /// 完整保存路径（models/{author}/{fileName}，I4 跨仓库同名隔离），
  /// 由父组件统一构造，同时作为下载任务 id 用于事件过滤
  final String savePath;

  /// 由父组件执行（含存储预检、蜂窝确认），完成后调用 manager.start
  final Future<void> Function() onStart;

  /// 下载完成后"加载运行"回调
  final void Function(String savePath) onRun;

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  DownloadTask? _task;
  StreamSubscription<DownloadTask>? _sub;
  bool _starting = false;

  String get _savePath => widget.savePath;

  @override
  void initState() {
    super.initState();
    _task = DownloadManager.instance.taskOf(_savePath);
    _sub = DownloadManager.instance.events.listen((t) {
      if (!mounted || t.id != _savePath) return;
      setState(() {
        // I2: 任务被 cancel/forget 移除后仍会广播末次事件，直接引用事件
        // 里的 t 会让按钮停留在已取消任务的僵尸状态，须回查实时任务表
        _task = DownloadManager.instance.taskOf(t.id);
      });
    });
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      await widget.onStart();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;

    // 目标文件已存在（本次下载完成或此前已导入）。
    // I1: completed 任务记录可能指向已被删除的文件（删除时记录未清理），
    // 渲染前实测存在性，丢失则回退下载入口（start 已支持重下）
    if ((task == null || task.status == DownloadStatus.completed) &&
        File(_savePath).existsSync()) {
      return TextButton.icon(
        onPressed: () => widget.onRun(_savePath),
        icon: const Icon(Icons.play_arrow),
        label: const Text('加载运行'),
      );
    }
    if (task == null) {
      return _buildDownloadEntry();
    }

    switch (task.status) {
      case DownloadStatus.downloading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: task.progress),
                  const SizedBox(height: 2),
                  Text(
                    '${(task.progress * 100).toStringAsFixed(0)}% · ${_fmtSpeed(task.speedBps)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '暂停',
              icon: const Icon(Icons.pause),
              onPressed: () => DownloadManager.instance.pause(task.id),
            ),
          ],
        );
      case DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton.icon(
              onPressed: () => DownloadManager.instance.resume(task.id),
              icon: const Icon(Icons.play_arrow),
              label: const Text('继续'),
            ),
            IconButton(
              tooltip: '取消并删除',
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => DownloadManager.instance.cancel(task.id),
            ),
          ],
        );
      case DownloadStatus.verifying:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('校验中…', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        );
      case DownloadStatus.completed:
        // I1: 走到这里说明文件已丢失（上方 existsSync 未通过），
        // 回退下载入口重新获取
        return _buildDownloadEntry();
      case DownloadStatus.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (task.error != null)
              Text(task.error!,
                  style: const TextStyle(fontSize: 11, color: Colors.red)),
            ElevatedButton.icon(
              onPressed: () => DownloadManager.instance.resume(task.id),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        );
      case DownloadStatus.queued:
        // 串行队列：已有任务在下载，本任务排队等待前序结束
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            const Text('排队中…',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            // Minor5: 排队任务可取消（尚未开始下载，出队并清理记录）
            IconButton(
              tooltip: '取消排队',
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => DownloadManager.instance.cancel(task.id),
            ),
          ],
        );
    }
  }

  Widget _buildDownloadEntry() => ElevatedButton.icon(
        onPressed: _starting ? null : _start,
        icon: _starting
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.download),
        label: const Text('下载'),
      );

  String _fmtSpeed(double bps) {
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
