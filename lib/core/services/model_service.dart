import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  final Dio _dio = Dio();
  late Directory _modelsDir;
  List<ModelInfo> _availableModels = [];
  String? _currentModelId;

  /// 推荐模型列表 (Qwen3.5 系列)
  final List<Map<String, dynamic>> recommendedModels = [
    {
      'id': 'qwen3.5-0.8b-q4km',
      'name': 'Qwen3.5-0.8B-Instruct (Q4_K_M)',
      'url': 'https://huggingface.co/bartowski/Qwen3.5-0.8B-Instruct-GGUF/resolve/main/Qwen3.5-0.8B-Instruct-Q4_K_M.gguf',
      'size': 620 * 1024 * 1024, // ~620MB
      'description': '平衡性能与体积，推荐大多数设备使用',
    },
    {
      'id': 'qwen3.5-0.8b-q5km',
      'name': 'Qwen3.5-0.8B-Instruct (Q5_K_M)',
      'url': 'https://huggingface.co/bartowski/Qwen3.5-0.8B-Instruct-GGUF/resolve/main/Qwen3.5-0.8B-Instruct-Q5_K_M.gguf',
      'size': 720 * 1024 * 1024, // ~720MB
      'description': '更高精度，适合高端设备',
    },
    {
      'id': 'qwen3.5-0.8b-q6k',
      'name': 'Qwen3.5-0.8B-Instruct (Q6_K)',
      'url': 'https://huggingface.co/bartowski/Qwen3.5-0.8B-Instruct-GGUF/resolve/main/Qwen3.5-0.8B-Instruct-Q6_K.gguf',
      'size': 850 * 1024 * 1024, // ~850MB
      'description': '最高精度，仅推荐旗舰设备',
    },
    {
      'id': 'qwen2.5-0.5b-q4km',
      'name': 'Qwen2.5-0.5B-Instruct (Q4_K_M)',
      'url': 'https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf',
      'size': 320 * 1024 * 1024, // ~320MB
      'description': '轻量级，适合低端设备或快速测试',
    },
  ];

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

  /// 扫描本地已下载的模型
  Future<void> _scanLocalModels() async {
    _availableModels.clear();
    
    final entries = _modelsDir.listSync();
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

  /// 下载模型 (带进度回调)
  Future<void> downloadModel({
    required String url,
    required String modelId,
    required String modelName,
    Function(double progress)? onProgress,
  }) async {
    // 请求存储权限 (仅 Android)
    if (Platform.isAndroid) {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        await Permission.storage.request();
      }
    }

    final fileName = '${modelId.replaceAll('-', '_')}.gguf';
    final savePath = '${_modelsDir.path}/$fileName';
    
    // 检查是否已存在
    final existingFile = File(savePath);
    if (await existingFile.exists()) {
      throw Exception('模型文件已存在');
    }

    await _dio.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total != -1) {
          final progress = received / total;
          if (onProgress != null) {
            onProgress(progress);
          }
        }
      },
    );

    // 重新扫描本地模型
    await _scanLocalModels();
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
