import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:edge_ai_app/core/services/chat_service.dart';
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

  // 下载任务跟踪（DownloadManager 事件驱动 + 重启回填）
  List<DownloadTask> _pendingTasks = const [];
  StreamSubscription<DownloadTask>? _dlSub;
  bool _isImporting = false;

  bool get _isDownloading => _pendingTasks.any((t) =>
      t.status == DownloadStatus.downloading ||
      t.status == DownloadStatus.verifying ||
      t.status == DownloadStatus.queued);

  /// 未完成的下载任务（含排队/下载/暂停/校验/失败）
  List<DownloadTask> _pendingTasksOf() =>
      DownloadManager.instance.tasks
          .where((t) => t.status != DownloadStatus.completed)
          .toList();

  @override
  void initState() {
    super.initState();
    _refreshModels();
    // 模型切换/导入/删除事件：刷新当前模型高亮与列表
    // （switchModel 只改内存不触发本页 setState，须事件驱动）
    _modelService.addListener(_onModelServiceChanged);
    // I2: 杀进程重启后 DownloadManager.init() 恢复的任务记录无事件可监听，
    // 须在此回填，否则自定义 URL 任务将失去"继续/取消"入口
    _pendingTasks = _pendingTasksOf();
    _dlSub = DownloadManager.instance.events.listen((t) {
      if (!mounted) return;
      setState(() => _pendingTasks = _pendingTasksOf());
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

  void _onModelServiceChanged() {
    if (mounted) setState(() {});
  }

  /// 从外部导入模型。
  /// 注意：Android 上 FileType.custom + .gguf（无 MIME 映射）会导致文件灰选，
  /// 改用 FileType.any 让用户任选文件，选中后手动校验 .gguf 扩展名。
  Future<void> _importModel() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
      );

      final path = result?.files.single.path;
      if (path == null) return; // 用户取消

      if (!path.toLowerCase().endsWith('.gguf')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('仅支持 .gguf 格式的模型文件，请重新选择')),
          );
        }
        return;
      }

      setState(() => _isImporting = true);

      // 大文件复制在独立 Isolate 执行，避免阻塞 UI
      final imported = await _modelService.importModel(path);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(imported ?? '模型导入成功')),
        );
        await _refreshModels();
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
      // 通知聊天服务失效缓存（切回对话页自动热加载新模型）
      ChatService().invalidate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('模型已切换，前往对话页即可使用')),
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

            // I2: 下载任务区块（含杀进程重启后恢复的任务）
            if (_pendingTasks.isNotEmpty) ...[
              _buildDownloadTasksSection(),
              const SizedBox(height: 24),
            ],

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
            // I2: 进度展示移至"下载任务"区块统一承载（覆盖全部任务来源）
          ],
        ),
      ),
    );
  }

  /// I2: 下载任务区块——渲染全部未完成任务（含重启恢复的），
  /// 提供暂停/继续/取消/重试入口
  Widget _buildDownloadTasksSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '下载任务',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ..._pendingTasks.map(_buildDownloadTaskCard),
      ],
    );
  }

  Widget _buildDownloadTaskCard(DownloadTask task) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                _buildTaskActions(task),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              // 总大小未知（totalBytes = -1）时走不定进度动画
              value: task.totalBytes > 0 ? task.progress : null,
            ),
            const SizedBox(height: 4),
            Text(
              _taskStatusLine(task),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (task.status == DownloadStatus.failed &&
                task.error != null) ...[
              const SizedBox(height: 2),
              Text(
                task.error!,
                style: const TextStyle(fontSize: 11, color: Colors.red),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 按状态渲染操作按钮：downloading → 暂停；paused → 继续+取消；
  /// queued → 取消排队；failed → 重试；verifying 无操作
  Widget _buildTaskActions(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.downloading:
        return IconButton(
          tooltip: '暂停',
          icon: const Icon(Icons.pause),
          onPressed: () => DownloadManager.instance.pause(task.id),
        );
      case DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => DownloadManager.instance.resume(task.id),
              child: const Text('继续'),
            ),
            IconButton(
              tooltip: '取消并删除',
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => DownloadManager.instance.cancel(task.id),
            ),
          ],
        );
      case DownloadStatus.queued:
        return IconButton(
          tooltip: '取消排队',
          icon: const Icon(Icons.close, color: Colors.red),
          onPressed: () => DownloadManager.instance.cancel(task.id),
        );
      case DownloadStatus.failed:
        return TextButton(
          onPressed: () => DownloadManager.instance.resume(task.id),
          child: const Text('重试'),
        );
      case DownloadStatus.verifying:
      case DownloadStatus.completed:
        return const SizedBox.shrink();
    }
  }

  String _taskStatusLine(DownloadTask task) {
    final buffer = StringBuffer(_statusLabelOf(task.status));
    if (task.totalBytes > 0) {
      buffer.write(' · ${(task.progress * 100).toStringAsFixed(1)}%');
    } else if (task.receivedBytes > 0) {
      buffer.write(' · 已下载 ${_fmtBytes(task.receivedBytes)}');
    }
    if (task.status == DownloadStatus.downloading && task.speedBps > 0) {
      buffer.write(' · ${_fmtSpeed(task.speedBps)}');
    }
    return buffer.toString();
  }

  String _statusLabelOf(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.queued:
        return '排队中';
      case DownloadStatus.downloading:
        return '下载中';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.verifying:
        return '校验中';
      case DownloadStatus.completed:
        return '已完成';
      case DownloadStatus.failed:
        return '失败';
    }
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  String _fmtSpeed(double bps) {
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
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
    _modelService.removeListener(_onModelServiceChanged);
    _dlSub?.cancel();
    _urlController.dispose();
    super.dispose();
  }
}
