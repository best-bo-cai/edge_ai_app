import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:edge_ai_app/core/models/hf_catalog_models.dart';
import 'package:edge_ai_app/core/services/download_manager.dart';

/// 模型信息数据类
class ModelInfo {
  final String id;
  final String name;
  final String path;
  final int sizeBytes;
  final bool isDownloaded;
  final DateTime? downloadDate;

  ModelInfo({
    required this.id,
    required this.name,
    required this.path,
    required this.sizeBytes,
    this.isDownloaded = false,
    this.downloadDate,
  });

  String get sizeLabel {
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    } else if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  ModelInfo copyWith({
    String? id,
    String? name,
    String? path,
    int? sizeBytes,
    bool? isDownloaded,
    DateTime? downloadDate,
  }) {
    return ModelInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      path: path ?? this.path,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      downloadDate: downloadDate ?? this.downloadDate,
    );
  }
}

/// 模型管理服务
class ModelService {
  static final ModelService _instance = ModelService._internal();
  factory ModelService() => _instance;
  ModelService._internal();

  late Directory _modelsDir;
  List<ModelInfo> _availableModels = [];
  String? _currentModelId;

  static const String _fallbackAssetPath = 'assets/data/fallback_models.json';

  /// 解析兜底清单 JSON（需求 3.1）
  /// 逐条容错：单条坏数据仅跳过该条并记录日志，不影响其余条目
  static List<HfModel> parseFallbackJson(String raw) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('ModelService: 兜底清单 JSON 解析失败: $e');
      return const [];
    }
    final models = data['models'];
    if (models is! List) {
      debugPrint('ModelService: 兜底清单缺少 models 数组，实际类型 ${models.runtimeType}');
      return const [];
    }
    final result = <HfModel>[];
    for (var i = 0; i < models.length; i++) {
      try {
        result.add(HfModel.fromJson(models[i] as Map<String, dynamic>));
      } catch (e) {
        debugPrint('ModelService: 兜底清单第 $i 条解析失败，已跳过: $e');
      }
    }
    return result;
  }

  /// 网络异常时加载内置精选清单
  Future<List<HfModel>> loadFallbackModels() async {
    try {
      return parseFallbackJson(await rootBundle.loadString(_fallbackAssetPath));
    } catch (e) {
      debugPrint('ModelService: 兜底清单资产加载失败($_fallbackAssetPath): $e');
      return const [];
    }
  }

  /// 初始化服务
  Future<void> init() async {
    _modelsDir = await _getModelsDirectory();
    await _scanLocalModels();
    
    // 加载上次使用的模型
    final prefs = await SharedPreferences.getInstance();
    _currentModelId = prefs.getString('current_model_id');
  }

  /// 获取模型存储目录
  Future<Directory> _getModelsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory('${appDir.path}/models');
    
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    
    return modelsDir;
  }

  /// 扫描本地已下载的模型。
  /// I4: 递归扫描子目录（models/{author}/{fileName}），
  /// 兼容平铺在 models 根目录的旧文件
  Future<void> _scanLocalModels() async {
    _availableModels.clear();

    final entries = _modelsDir.listSync(recursive: true);
    for (final entry in entries) {
      if (entry is File && entry.path.endsWith('.gguf')) {
        final stat = await entry.stat();
        final fileName = entry.uri.pathSegments.last;
        
        _availableModels.add(ModelInfo(
          id: fileName.replaceAll('.gguf', '').toLowerCase().replaceAll('_', '-'),
          name: fileName.replaceAll('.gguf', ''),
          path: entry.path,
          sizeBytes: stat.size,
          isDownloaded: true,
          downloadDate: stat.modified,
        ));
      }
    }
  }

  /// 获取所有可用模型
  List<ModelInfo> get availableModels => _availableModels;

  /// 获取当前选中的模型
  String? get currentModelId => _currentModelId;

  /// 获取当前模型路径
  String? get currentModelPath {
    if (_currentModelId == null) return null;
    final model = _availableModels.firstWhere(
      (m) => m.id == _currentModelId,
      orElse: () => throw Exception('Model not found'),
    );
    return model.path;
  }

  /// 自定义 URL 下载（统一走 DownloadManager，支持暂停/续传/校验）
  Future<DownloadTask> downloadModel({
    required String url,
    required String modelName,
  }) async {
    final fileName = url.split('?').first.split('/').last;
    if (!fileName.toLowerCase().endsWith('.gguf')) {
      throw Exception('仅支持 .gguf 文件直链');
    }
    return DownloadManager.instance.start(
      url: url,
      displayName: modelName,
      savePath: '${_modelsDir.path}/$fileName',
    );
  }

  /// 从外部导入模型文件
  Future<void> importModel(String sourcePath) async {
    final sourceFile = File(sourcePath);
    
    if (!await sourceFile.exists()) {
      throw Exception('源文件不存在');
    }

    if (!sourcePath.endsWith('.gguf')) {
      throw Exception('仅支持 .gguf 格式的模型文件');
    }

    final fileName = sourceFile.uri.pathSegments.last;
    String destPath = '${_modelsDir.path}/$fileName';
    
    // 如果已存在，添加时间戳
    if (await File(destPath).exists()) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final baseName = fileName.replaceAll('.gguf', '');
      final newFileName = '${baseName}_$timestamp.gguf';
      destPath = '${_modelsDir.path}/$newFileName';
    }
    
    final destFile = File(destPath);

    await sourceFile.copy(destFile.path);
    await _scanLocalModels();
  }

  /// 删除模型
  Future<void> deleteModel(String modelId) async {
    final model = _availableModels.firstWhere(
      (m) => m.id == modelId,
      orElse: () => throw Exception('模型不存在'),
    );

    final file = File(model.path);
    if (await file.exists()) {
      await file.delete();

      // I1: 联动清除下载任务记录，避免详情页 completed 态
      // 指向已删除的文件（渲染死锁）
      await DownloadManager.instance.forget(model.path);

      // 如果删除的是当前模型，清空当前选择
      if (_currentModelId == modelId) {
        _currentModelId = null;
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('current_model_id');
      }
      
      await _scanLocalModels();
    }
  }

  /// 切换当前模型
  Future<void> switchModel(String modelId) async {
    final model = _availableModels.firstWhere(
      (m) => m.id == modelId,
      orElse: () => throw Exception('模型不存在'),
    );

    if (!model.isDownloaded) {
      throw Exception('模型未下载');
    }

    _currentModelId = modelId;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_model_id', modelId);
  }

  /// 模型存储目录（main 中 init 后可用）
  String get modelsDirPath => _modelsDir.path;

  /// 按文件路径加载运行（详情页"加载运行"入口）
  Future<void> switchModelByPath(String path) async {
    await _scanLocalModels();
    final model = _availableModels.firstWhere(
      (m) => m.path == path,
      orElse: () => throw Exception('模型不存在'),
    );
    await switchModel(model.id);
  }

  /// 检查模型是否已下载
  bool isModelDownloaded(String modelId) {
    return _availableModels.any((m) => m.id == modelId && m.isDownloaded);
  }

  /// 获取模型下载状态
  ModelInfo? getModelInfo(String modelId) {
    try {
      return _availableModels.firstWhere((m) => m.id == modelId);
    } catch (e) {
      return null;
    }
  }
}
