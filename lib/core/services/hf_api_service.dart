// lib/core/services/hf_api_service.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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

  /// 全局单例：镜像状态（activeHost）跨页面共享；测试可继续用构造函数注入自定义 Dio
  static final HfApiService instance = HfApiService();

  final Dio _dio;
  String activeHost = officialHost;

  /// 最近一次成功落盘的数据源；null 表示未知（下次成功请求会补写一次盘）
  String? _persistedHost;

  /// [dio] 可注入用于测试或定制拦截器；注意注入时不会应用下方默认超时，
  /// 调用方需自行配置 connectTimeout/receiveTimeout，避免请求无限挂起。
  HfApiService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
            ));

  /// 启动时恢复上次可用数据源（首屏提速）；仅接受白名单内的主机，脏数据回退官方源
  Future<void> restoreHost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_hostPrefKey);
      if (saved == mirrorHost) {
        activeHost = mirrorHost;
      } else {
        if (saved != null && saved != officialHost) {
          debugPrint('HfApiService: 忽略未知数据源 "$saved"，回退官方源');
        }
        activeHost = officialHost;
      }
      _persistedHost = activeHost;
    } catch (e) {
      debugPrint('HfApiService: 恢复数据源失败: $e');
    }
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
      await _rememberHost(activeHost);
      return result;
    } on DioException catch (e) {
      if (!_isConnError(e)) {
        throw HfApiException(_failureMessage(e));
      }
      final alt = activeHost == officialHost ? mirrorHost : officialHost;
      try {
        final result = await run(alt);
        activeHost = alt;
        await _rememberHost(alt);
        return result;
      } on DioException catch (e2) {
        // 备用源 badResponse 携带业务语义（如 404"仓库不存在"），透传而非误报"双源均不可用"
        throw HfApiException(
          _isConnError(e2) ? '官方源与镜像均不可用: $e2' : _failureMessage(e2),
        );
      } catch (e2) {
        throw HfApiException('响应解析失败: $e2');
      }
    } catch (e) {
      // 兜底：非 DioException（如 200 但非 JSON 时 as 转换抛出的 TypeError）
      throw HfApiException('响应解析失败: $e');
    }
  }

  bool _isConnError(DioException e) =>
      e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.connectionError ||
      e.type == DioExceptionType.receiveTimeout;

  String _failureMessage(DioException e) {
    final status = e.response?.statusCode;
    return status != null ? '请求失败(HTTP $status)' : '请求失败: ${e.message}';
  }

  /// 仅在数据源切换/变化时写盘并 await，成功后同步内存缓存
  Future<void> _rememberHost(String host) async {
    if (_persistedHost == host) return; // 未变化，免写盘
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hostPrefKey, host);
      _persistedHost = host;
    } catch (e) {
      debugPrint('HfApiService: 持久化数据源失败: $e');
    }
  }
}
