import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:edge_ai_app/core/services/download_manager.dart';
import '../../core/services/model_service.dart';
import '../model_market/model_market_screen.dart';

/// 模型管理页面 - 支持下载、导入、切换模型
class ModelManagementScreen extends StatefulWidget {
  const ModelManagementScreen({super.key});

  @override
  State<ModelManagementScreen> createState() => _ModelManagementScreenState();
}

class _ModelManagementScreenState extends State<ModelManagementScreen> {
  final ModelService _modelService = ModelService();
  final TextEditingController _urlController = TextEditingController();
  
  // 下载状态跟踪（DownloadManager 事件驱动）
  DownloadTask? _activeTask;
  StreamSubscription<DownloadTask>? _dlSub;
  bool _isImporting = false;

  bool get _isDownloading =>
      _activeTask?.status == DownloadStatus.downloading ||
      _activeTask?.status == DownloadStatus.verifying ||
      _activeTask?.status == DownloadStatus.queued;

  @override
  void initState() {
    super.initState();
    _refreshModels();
    _dlSub = DownloadManager.instance.events.listen((t) {
      if (!mounted) return;
      setState(() => _activeTask = DownloadManager.instance.taskOf(t.id));
      // 下载完成后刷新已下载列表（管理页常驻 IndexedStack，需事件驱动刷新）
      if (t.status == DownloadStatus.completed) {
        _refreshModels();
      }
    });
  }

  Future<void> _refreshModels() async {
    await _modelService.init();
    if (mounted) setState(() {});
  }

  /// 从外部导入模型
  Future<void> _importModel() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gguf'],
      );

      if (result != null && result.files.single.path != null) {
        setState(() => _isImporting = true);

        await _modelService.importModel(result.files.single.path!);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('模型导入成功')),
          );
          await _refreshModels();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// 自定义 URL 下载
  Future<void> _downloadFromCustomUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的下载链接')),
      );
      return;
    }

    if (!url.startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL 必须以 http 或 https 开头')),
      );
      return;
    }

    // 从 URL 提取文件名作为展示名
    final fileName = p.basename(url.split('?').first);
    final modelName = fileName.replaceAll('.gguf', '');

    if (_isDownloading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已有下载任务正在进行')),
      );
      return;
    }

    try {
      await _modelService.downloadModel(url: url, modelName: modelName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('开始下载，可离开此页面，下载将自动继续')),
        );
        _urlController.clear();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败：$e')),
        );
      }
    }
  }

  /// 切换模型
  Future<void> _switchModel(String modelId) async {
    try {
      await _modelService.switchModel(modelId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('模型已切换，重启应用生效')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('切换失败：$e')),
        );
      }
    }
  }

  /// 删除模型
  Future<void> _deleteModel(String modelId, String modelName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除 $modelName 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _modelService.deleteModel(modelId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('模型已删除')),
          );
          await _refreshModels();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('删除失败：$e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final availableModels = _modelService.availableModels;
    final currentModelId = _modelService.currentModelId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('模型管理'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 模型广场入口（在线推荐 + 设备适配筛选）
            Card(
              child: ListTile(
                leading: const Icon(Icons.storefront, color: Colors.blue),
                title: const Text('模型广场'),
                subtitle: const Text('浏览 HuggingFace 推荐模型，按本机配置智能筛选'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ModelMarketScreen()),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // 自定义 URL 下载卡片
            _buildCustomDownloadCard(),

            const SizedBox(height: 24),

            // 导入按钮
            _buildImportButton(),

            const SizedBox(height: 24),

            // 已下载模型列表
            if (availableModels.isNotEmpty) ...[
              const Text(
                '已下载的模型',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ...availableModels.map((model) => 
                _buildLocalModelCard(model, currentModelId),
              ),
            ] else ...[
              const Center(
                child: Text(
                  '暂无已下载的模型\n请从上方下载或导入模型文件',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCustomDownloadCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '自定义模型下载',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '输入 HuggingFace 或其他来源的 .gguf 文件直链',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                hintText: 'https://huggingface.co/.../model.gguf',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: _isDownloading ? null : _downloadFromCustomUrl,
                ),
              ),
              enabled: !_isDownloading,
            ),
            if (_activeTask != null && _isDownloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _activeTask!.progress),
              const SizedBox(height: 4),
              Text(
                '${(_activeTask!.progress * 100).toStringAsFixed(1)}%'
                '${_activeTask!.status == DownloadStatus.verifying ? " · 校验中" : ""}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildImportButton() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.folder_open),
        title: const Text('从本地导入模型'),
        subtitle: const Text('选择已下载的 .gguf 文件'),
        trailing: const Icon(Icons.chevron_right),
        onTap: (_isDownloading || _isImporting) ? null : _importModel,
      ),
    );
  }

  Widget _buildLocalModelCard(ModelInfo model, String? currentModelId) {
    final isCurrent = model.id == currentModelId;

    return Card(
      color: isCurrent ? Colors.blue.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              isCurrent ? Icons.check_circle : Icons.smart_toy,
              color: isCurrent ? Colors.blue : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: isCurrent ? Colors.blue : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '大小：${model.sizeLabel}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  if (model.downloadDate != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '下载于：${_formatDate(model.downloadDate!)}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ],
              ),
            ),
            if (!isCurrent)
              TextButton(
                onPressed: () => _switchModel(model.id),
                child: const Text('切换'),
              ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () => _deleteModel(model.id, model.name),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _dlSub?.cancel();
    _urlController.dispose();
    super.dispose();
  }
}
