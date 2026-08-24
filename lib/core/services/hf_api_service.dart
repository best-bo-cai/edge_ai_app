// lib/core/services/hf_api_service.dart
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/hf_catalog_models.dart';

/// HF 数据源不可用（触发兜底清单）
class HfApiException implements Exception {
  final String message;
  const HfApiException(this.message);
  @override
  String toString() => 'HfApiException: $message';
}

/// Hugging Face Hub API 客户端（需求 2.2），官方源/镜像自动回退
class HfApiService {
  static const String officialHost = 'https://huggingface.co';
  static const String mirrorHost = 'https://hf-mirror.com';
  static const String _hostPrefKey = 'hf_active_host';

  final Dio _dio;
  String activeHost = officialHost;

  HfApiService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
            ));

  /// 启动时恢复上次可用数据源（首屏提速）
  Future<void> restoreHost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      activeHost = prefs.getString(_hostPrefKey) ?? officialHost;
    } catch (_) {}
  }

  /// 推荐模型列表：GET /api/models（filter=gguf, sort=downloads, direction=-1）
  Future<List<HfModel>> searchModels({String? query, int limit = 30, int skip = 0}) async {
    final data = await _withHostFallback((host) async {
      final params = <String, dynamic>{
        'filter': 'gguf',
        'sort': 'downloads',
        'direction': -1,
        'full': 'true',
        'limit': limit,
        'skip': skip,
      };
      final q = query?.trim();
      if (q != null && q.isNotEmpty) params['search'] = q;
      final res = await _dio.get('$host/api/models', queryParameters: params);
      return res.data as List<dynamic>;
    });
    final list = data as List<dynamic>;
    return list.map((e) => HfModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 仓库文件列表：GET /api/models/{id}/tree/main，仅保留 .gguf
  Future<List<HfModelFile>> getModelFiles(String repoId) async {
    final data = await _withHostFallback((host) async {
      final res = await _dio.get('$host/api/models/$repoId/tree/main');
      return res.data as List<dynamic>;
    });
    final list = data as List<dynamic>;
    return list
        .map((e) => e as Map<String, dynamic>)
        .where((e) =>
            (e['type'] ?? 'file') == 'file' &&
            (e['path'] as String).toLowerCase().endsWith('.gguf'))
        .map((e) => HfModelFile.fromJson(repoId, e))
        .toList();
  }

  /// 下载直链：{host}/{repoId}/resolve/main/{fileName}
  String downloadUrl(String repoId, String fileName) =>
      '$activeHost/$repoId/resolve/main/$fileName';

  /// 连接类失败时切换数据源重试一次，成功后持久化（镜像策略见技术设计 4.2）
  Future<dynamic> _withHostFallback(Future<dynamic> Function(String host) run) async {
    try {
      final result = await run(activeHost);
      _rememberHost(activeHost);
      return result;
    } on DioException catch (e) {
      final isConnError = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.receiveTimeout;
      if (!isConnError) {
        throw HfApiException('请求失败: ${e.message}');
      }
      final alt = activeHost == officialHost ? mirrorHost : officialHost;
      try {
        final result = await run(alt);
        activeHost = alt;
        _rememberHost(alt);
        return result;
      } catch (e2) {
        throw HfApiException('官方源与镜像均不可用: $e2');
      }
    }
  }

  Future<void> _rememberHost(String host) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hostPrefKey, host);
    } catch (_) {}
  }
}
