// test/hf_api_service_test.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_app/core/services/hf_api_service.dart';

/// 记录请求并可注入响应/异常的 Dio 适配器
class MockAdapter implements HttpClientAdapter {
  MockAdapter(this.handler);
  final Future<Object?> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final result = await handler(options);
    if (result is ResponseBody) return result;
    final json = jsonEncode(result);
    return ResponseBody.fromString(json, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('searchModels 拼装需求参数并解析模型', () async {
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      return [
        {'id': 'Qwen/Qwen2.5-0.5B-Instruct-GGUF', 'downloads': 1000, 'likes': 10, 'tags': ['gguf']},
      ];
    });
    final api = HfApiService(dio: dio);
    final models = await api.searchModels(query: 'qwen');

    expect(models.single.id, 'Qwen/Qwen2.5-0.5B-Instruct-GGUF');
    expect(models.single.downloads, 1000);

    final req = (dio.httpClientAdapter as MockAdapter).requests.single;
    expect(req.queryParameters['filter'], 'gguf');
    expect(req.queryParameters['sort'], 'downloads');
    expect(req.queryParameters['direction'], -1);
    expect(req.queryParameters['search'], 'qwen');
    expect(req.uri.toString(), contains('huggingface.co/api/models'));
  });

  test('官方源连接失败自动切换镜像并记住', () async {
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      if (options.uri.host == 'huggingface.co') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        );
      }
      return [
        {'id': 'a/b-GGUF', 'downloads': 1, 'likes': 1, 'tags': []},
      ];
    });
    final api = HfApiService(dio: dio);
    final models = await api.searchModels();

    expect(models.single.id, 'a/b-GGUF');
    expect(api.activeHost, HfApiService.mirrorHost);
    // 下一次请求直接走镜像
    await api.searchModels();
    final hosts = (dio.httpClientAdapter as MockAdapter)
        .requests
        .map((r) => r.uri.host)
        .toList();
    expect(hosts, ['huggingface.co', 'hf-mirror.com', 'hf-mirror.com']);
  });

  test('getModelFiles 仅保留 .gguf 且提取 lfs.oid', () async {
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      return [
        {'type': 'file', 'path': 'README.md', 'size': 100},
        {'type': 'file', 'path': 'x-q4_k_m.gguf', 'size': 100, 'lfs': {'oid': 'abc', 'size': 100}},
        {'type': 'directory', 'path': 'sub'},
      ];
    });
    final api = HfApiService(dio: dio);
    final files = await api.getModelFiles('a/b');
    expect(files.single.path, 'x-q4_k_m.gguf');
    expect(files.single.sha256, 'abc');
  });

  test('双源均失败抛 HfApiException（触发兜底）', () async {
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    });
    final api = HfApiService(dio: dio);
    expect(() => api.searchModels(), throwsA(isA<HfApiException>()));
  });

  test('downloadUrl 直链构造（需求 2.2 规则）', () {
    final dio = Dio();
    final api = HfApiService(dio: dio);
    expect(
      api.downloadUrl('Qwen/Qwen2.5-0.5B-Instruct-GGUF', 'a.gguf'),
      'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/a.gguf',
    );
  });
}
