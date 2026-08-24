// lib/features/model_market/model_detail_screen.dart
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../../core/device/device_capability_service.dart';
import '../../core/models/compatibility.dart';
import '../../core/models/hf_catalog_models.dart';
import '../../core/services/download_manager.dart';
import '../../core/services/hf_api_service.dart';
import '../../core/services/model_service.dart';
import 'widgets/compat_badge.dart';
import 'widgets/download_button.dart';

/// 模型详情：仓库信息 + 量化文件列表 + 下载（需求 2.4）
class ModelDetailScreen extends StatefulWidget {
  const ModelDetailScreen({super.key, required this.model});
  final HfModel model;

  @override
  State<ModelDetailScreen> createState() => _ModelDetailScreenState();
}

class _ModelDetailScreenState extends State<ModelDetailScreen> {
  final HfApiService _api = HfApiService();
  final ModelService _modelService = ModelService();

  DeviceCapability? _capability;
  List<HfModelFile>? _files;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _capability = await DeviceCapabilityService().getCapability();
    try {
      _files = await _api.getModelFiles(widget.model.id);
    } catch (_) {
      _files = widget.model.files; // 兜底条目内嵌清单
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _error = _files == null || _files!.isEmpty ? '文件列表加载失败，请检查网络后重试' : null;
      });
    }
  }

  /// 下载保存路径：models/{author}/{fileName}（I4 跨仓库同名隔离，
  /// repoId 斜杠分割的首段作子目录，避免不同仓库的同名 GGUF 互相覆盖）
  String _savePathFor(HfModelFile file) =>
      '${_modelService.modelsDirPath}/${file.repoId.split('/').first}/${file.fileName}';

  /// 下载前拦截校验：存储空间（需求 2.4：≥ 文件+2GB）+ 蜂窝网络提醒
  Future<void> _onDownloadFile(HfModelFile file) async {
    final cap = _capability;
    if (cap != null &&
        !StorageCheck.hasEnoughSpace(
            freeDiskBytes: cap.freeDiskBytes, fileSizeBytes: file.sizeBytes)) {
      final need = file.sizeBytes + StorageCheck.runtimeCacheBytes;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('存储空间不足'),
          content: Text(
              '下载该文件约需 ${_fmtBytes(need)}（含 2GB 运行缓存），'
              '当前可用 ${_fmtBytes(cap.freeDiskBytes ?? 0)}。'
              '请清理空间后重试。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: const Text('知道了')),
          ],
        ),
      );
      return;
    }

    final networks = await Connectivity().checkConnectivity();
    if (!mounted) return;
    if (networks.contains(ConnectivityResult.mobile)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('正在使用移动网络'),
          content: Text(
              '即将下载 ${_fmtBytes(file.sizeBytes)} 的模型文件，'
              '可能消耗较多流量。是否继续？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续下载')),
          ],
        ),
      );
      if (ok != true) return;
    }

    try {
      await DownloadManager.instance.start(
        url: _api.downloadUrl(file.repoId, file.fileName),
        displayName: file.fileName,
        savePath: _savePathFor(file),
        totalBytes: file.sizeBytes,
        expectedSha256: file.sha256,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('开始下载失败：$e')));
      }
    }
  }

  /// 下载完成 → 加载运行（需求 2.4 快捷入口）
  Future<void> _onRunModel(String savePath) async {
    try {
      await _modelService.switchModelByPath(savePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('模型已加载，前往对话页开始体验吧')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('模型详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_error!, style: const TextStyle(color: Colors.grey)),
                    const SizedBox(height: 12),
                    ElevatedButton(onPressed: () {
                      setState(() => _loading = true);
                      _init();
                    }, child: const Text('重试')),
                  ],
                ))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildRepoCard(),
                    const SizedBox(height: 16),
                    const Text('量化版本',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ..._files!.map(_buildFileCard),
                  ],
                ),
    );
  }

  Widget _buildRepoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.model.name,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('作者：${widget.model.author}',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 8),
            Text('仓库：${widget.model.id}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            if (widget.model.tags.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: widget.model.tags
                    .where((t) => !t.contains(':'))
                    .take(6)
                    .map((t) => Chip(
                          label: Text(t, style: const TextStyle(fontSize: 10)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileCard(HfModelFile file) {
    final quant = file.quant;
    final level = _capability == null
        ? CompatibilityLevel.unknown
        : CompatibilityEngine.evaluateFile(_capability!, file);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(file.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        '${quant?.label ?? "未知量化"} · ${quant?.quality ?? "详见仓库文档"} · ${_fmtBytes(file.sizeBytes)}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                CompatBadge(level: level),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DownloadButton(
                    savePath: _savePathFor(file),
                    onStart: () => _onDownloadFile(file),
                    onRun: _onRunModel,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}
