// test/hf_api_service_test.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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

  test('切换镜像后落盘 hf_active_host，新实例 restoreHost 恢复镜像', () async {
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      if (options.uri.host == 'huggingface.co') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        );
      }
      return <Map<String, dynamic>>[
        {'id': 'a/b-GGUF', 'downloads': 1, 'likes': 1, 'tags': []},
      ];
    });
    final api = HfApiService(dio: dio);
    await api.searchModels();

    // 验证落盘
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('hf_active_host'), HfApiService.mirrorHost);

    // 模拟重启：新实例从磁盘恢复
    final api2 = HfApiService(dio: dio);
    await api2.restoreHost();
    expect(api2.activeHost, HfApiService.mirrorHost);
  });

  test('restoreHost 白名单校验：脏数据回退官方源', () async {
    SharedPreferences.setMockInitialValues({
      'hf_active_host': 'https://evil.example.com',
    });
    final api = HfApiService(dio: Dio());
    await api.restoreHost();
    expect(api.activeHost, HfApiService.officialHost);
  });

  test('badResponse（如仓库不存在）不切源，仅请求一次并透传状态码', () async {
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: options, statusCode: 404),
      );
    });
    final api = HfApiService(dio: dio);
    final future = api.getModelFiles('a/not-exist');
    await expectLater(
      future,
      throwsA(isA<HfApiException>().having(
        (e) => e.message,
        'message',
        contains('404'),
      )),
    );
    expect((dio.httpClientAdapter as MockAdapter).requests.length, 1);
    expect(api.activeHost, HfApiService.officialHost);
  });

  test('镜像连接失败反向回退官方源', () async {
    SharedPreferences.setMockInitialValues({
      'hf_active_host': HfApiService.mirrorHost,
    });
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      if (options.uri.host == 'hf-mirror.com') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        );
      }
      return <Map<String, dynamic>>[
        {'id': 'a/b-GGUF', 'downloads': 1, 'likes': 1, 'tags': []},
      ];
    });
    final api = HfApiService(dio: dio);
    await api.restoreHost();
    await api.searchModels();

    expect(api.activeHost, HfApiService.officialHost);
    final hosts = (dio.httpClientAdapter as MockAdapter)
        .requests
        .map((r) => r.uri.host)
        .toList();
    expect(hosts, ['hf-mirror.com', 'huggingface.co']);
  });

  test('200 但非 JSON 数组时包装为 HfApiException（不裸抛 TypeError）', () async {
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      return {'error': 'not a list'};
    });
    final api = HfApiService(dio: dio);
    await expectLater(
      api.searchModels(),
      throwsA(isA<HfApiException>()),
    );
  });

  test('备用源 badResponse 透传业务语义，不误报"双源均不可用"', () async {
    final dio = Dio()..httpClientAdapter = MockAdapter((options) async {
      if (options.uri.host == 'huggingface.co') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        );
      }
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: options, statusCode: 404),
      );
    });
    final api = HfApiService(dio: dio);
    await expectLater(
      api.getModelFiles('a/b'),
      throwsA(isA<HfApiException>().having(
        (e) => e.message,
        'message',
        allOf(contains('404'), isNot(contains('均不可用'))),
      )),
    );
  });
}
