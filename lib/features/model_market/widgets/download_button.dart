// lib/features/model_market/widgets/download_button.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/models/hf_catalog_models.dart';
import '../../../core/services/download_manager.dart';

/// 单文件下载按钮：下载 → 进度+速度+暂停 → 校验中 → 完成(加载运行)
/// 暂停 → 继续/取消；失败 → 重试（需求 2.4）
class DownloadButton extends StatefulWidget {
  const DownloadButton({
    super.key,
    required this.file,
    required this.modelsDirPath,
    required this.onStart,
    required this.onRun,
  });

  final HfModelFile file;
  final String modelsDirPath;

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
  bool _fileExists = false;
  bool _starting = false;

  String get _savePath => '${widget.modelsDirPath}/${widget.file.fileName}';

  @override
  void initState() {
    super.initState();
    _task = DownloadManager.instance.taskOf(_savePath);
    _fileExists = File(_savePath).existsSync();
    _sub = DownloadManager.instance.events.listen((t) {
      if (!mounted || t.id != _savePath) return;
      setState(() {
        _task = t;
        if (t.status == DownloadStatus.completed) _fileExists = true;
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

    // 目标文件已存在（本次下载完成或此前已导入）
    if (_fileExists &&
        (task == null || task.status == DownloadStatus.completed)) {
      return TextButton.icon(
        onPressed: () => widget.onRun(_savePath),
        icon: const Icon(Icons.play_arrow),
        label: const Text('加载运行'),
      );
    }
    if (task == null) {
      return ElevatedButton.icon(
        onPressed: _starting ? null : _start,
        icon: _starting
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.download),
        label: const Text('下载'),
      );
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
        return TextButton.icon(
          onPressed: () => widget.onRun(_savePath),
          icon: const Icon(Icons.play_arrow),
          label: const Text('加载运行'),
        );
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
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('排队中…', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        );
    }
  }

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
