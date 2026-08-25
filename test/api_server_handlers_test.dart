// test/api_server_handlers_test.dart
// API 服务协议层测试：鉴权 / 模型严格匹配(ADR-0002) / 请求校验 / SSE 格式。
// 不依赖 Flutter 引擎与真实推理——调度器以假引擎注入路径测试（纯 Dart HttpServer 回环）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:edge_ai_app/core/services/model_service.dart';
import 'package:edge_ai_app/core/services/api_server/inference_scheduler.dart';
import 'package:edge_ai_app/core/services/api_server/openai_handlers.dart';
import 'package:edge_ai_app/core/services/api_server/anthropic_handlers.dart';

/// 测试桩：不走真实推理，返回固定文本
class _StubScheduler extends InferenceScheduler {
  final String fixedContent;
  _StubScheduler(this.fixedContent);

  @override
  Future<ApiGenerationResult> runGeneration({
    required String modelId,
    required List<MapEntry<String, String>> messages,
    TokenSink? onToken,
  }) async {
    // 模拟 3 个 token 片段流式回调
    for (final piece in fixedContent.split(' ')) {
      onToken?.call('$piece ');
    }
    return ApiGenerationResult(
      ok: true,
      content: '$fixedContent ',
      promptTokens: 10,
      outputTokens: 5,
    );
  }
}

/// 测试桩：固定模型清单
class _StubModelService implements ModelService {
  @override
  List<ModelInfo> get availableModels => [
        ModelInfo(
          id: 'qwen-test',
          name: 'Qwen Test',
          path: '/tmp/qwen-test.gguf',
          sizeBytes: 1024,
          isDownloaded: true,
        ),
      ];

  @override
  ModelInfo? getModelInfo(String modelId) =>
      modelId == 'qwen-test' ? availableModels.first : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late HttpServer server;
  late _StubModelService modelService;
  late InferenceScheduler scheduler;
  const apiKey = 'test-key-123';

  setUp(() async {
    modelService = _StubModelService();
    scheduler = _StubScheduler('hello world from edge');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      // 与 ApiServerService._authorize 一致的测试鉴权
      final auth = request.headers.value(HttpHeaders.authorizationHeader);
      final xKey = request.headers.value('x-api-key');
      final ok = (auth == 'Bearer $apiKey') || (xKey == apiKey);
      if (!ok) {
        request.response.statusCode = 401;
        request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      switch (request.uri.path) {
        case '/v1/models':
          await OpenAiHandlers.handleModels(request, modelService.availableModels);
        case '/v1/chat/completions':
          await OpenAiHandlers.handleChatCompletions(
            request, body,
            modelService: modelService, scheduler: scheduler,
          );
        case '/v1/messages':
          await AnthropicHandlers.handleMessages(
            request, body,
            modelService: modelService, scheduler: scheduler,
          );
        default:
          request.response.statusCode = 404;
          request.response.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<(int, String, Map<String, String>)> post(
    String path,
    Object body, {
    Map<String, String>? headers,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      headers?.forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final resp = await req.close();
      final text = await utf8.decoder.bind(resp).join();
      final respHeaders = <String, String>{};
      resp.headers.forEach((name, values) {
        respHeaders[name] = values.join(',');
      });
      return (resp.statusCode, text, respHeaders);
    } finally {
      client.close();
    }
  }

  group('鉴权', () {
    test('无 API key 返回 401', () async {
      final (status, _, _) = await post('/v1/chat/completions', {
        'model': 'qwen-test',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      });
      expect(status, 401);
    });

    test('Bearer 鉴权通过（OpenAI 风格）', () async {
      final (status, _, _) = await post('/v1/chat/completions', {
        'model': 'qwen-test',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }, headers: {
        'Authorization': 'Bearer $apiKey',
      });
      expect(status, 200);
    });

    test('x-api-key 鉴权通过（Anthropic 风格）', () async {
      final (status, _, _) = await post('/v1/messages', {
        'model': 'qwen-test',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }, headers: {
        'x-api-key': apiKey,
      });
      expect(status, 200);
    });
  });

  group('模型严格匹配（ADR-0002）', () {
    test('OpenAI 端点：未安装模型返回 404 + model_not_found', () async {
      final (status, body, _) = await post('/v1/chat/completions', {
        'model': 'not-installed-model',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }, headers: {
        'Authorization': 'Bearer $apiKey',
      });
      expect(status, 404);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['error']['code'], 'model_not_found');
    });

    test('Anthropic 端点：未安装模型返回 404', () async {
      final (status, body, _) = await post('/v1/messages', {
        'model': 'not-installed-model',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }, headers: {
        'x-api-key': apiKey,
      });
      expect(status, 404);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['type'], 'error');
      expect(json['error']['type'], 'not_found_error');
    });
  });

  group('请求校验', () {
    test('缺 model 字段返回 400', () async {
      final (status, body, _) = await post('/v1/chat/completions', {
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }, headers: {
        'Authorization': 'Bearer $apiKey',
      });
      expect(status, 400);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['error']['type'], 'invalid_request_error');
    });

    test('非法 JSON 返回 400', () async {
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions'),
      );
      req.headers.set('Authorization', 'Bearer $apiKey');
      req.headers.contentType = ContentType.json;
      req.write('not-json');
      final resp = await req.close();
      final text = await utf8.decoder.bind(resp).join();
      client.close();
      expect(resp.statusCode, 400);
      expect((jsonDecode(text) as Map<String, dynamic>)['error']['type'],
          'invalid_request_error');
    });
  });

  group('OpenAI 兼容响应', () {
    test('非流式：choices 结构 + usage', () async {
      final (status, body, _) = await post('/v1/chat/completions', {
        'model': 'qwen-test',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }, headers: {
        'Authorization': 'Bearer $apiKey',
      });
      expect(status, 200);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['object'], 'chat.completion');
      expect(json['choices'][0]['message']['role'], 'assistant');
      expect(json['choices'][0]['message']['content'], isNotEmpty);
      expect(json['usage']['prompt_tokens'], 10);
      expect(json['usage']['completion_tokens'], 5);
      expect(json['usage']['total_tokens'], 15);
    });

    test('SSE 流式：chunk 结构 + [DONE] 收尾', () async {
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions'),
      );
      req.headers.set('Authorization', 'Bearer $apiKey');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'model': 'qwen-test',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }));
      final resp = await req.close();
      final text = await utf8.decoder.bind(resp).join();
      client.close();

      expect(resp.statusCode, 200);
      expect(text, contains('data: [DONE]'));

      final lines = text
          .split('\n')
          .where((l) => l.startsWith('data: ') && l != 'data: [DONE]')
          .map((l) => jsonDecode(l.substring(6)) as Map<String, dynamic>)
          .toList();
      // 至少：若干 token chunk + 1 个收尾 chunk（finish_reason=stop + usage）
      expect(lines, isNotEmpty);
      expect(lines.first['object'], 'chat.completion.chunk');
      expect(lines.first['choices'][0]['delta']['content'], isNotNull);

      final last = lines.last;
      expect(last['choices'][0]['finish_reason'], 'stop');
      expect(last['usage']['total_tokens'], 15);
    });
  });

  group('Anthropic 兼容响应', () {
    test('非流式：message 结构 + input/output tokens', () async {
      final (status, body, _) = await post('/v1/messages', {
        'model': 'qwen-test',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }, headers: {
        'x-api-key': apiKey,
      });
      expect(status, 200);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['type'], 'message');
      expect(json['role'], 'assistant');
      expect(json['content'][0]['type'], 'text');
      expect(json['content'][0]['text'], isNotEmpty);
      expect(json['usage']['input_tokens'], 10);
      expect(json['usage']['output_tokens'], 5);
    });

    test('SSE 流式：message_start → content_block_delta → message_stop', () async {
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/messages'),
      );
      req.headers.set('x-api-key', apiKey);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'model': 'qwen-test',
        'stream': true,
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }));
      final resp = await req.close();
      final text = await utf8.decoder.bind(resp).join();
      client.close();

      expect(resp.statusCode, 200);
      // 事件序列完整（Anthropic SDK 依赖此顺序）
      expect(text, contains('event: message_start'));
      expect(text, contains('event: content_block_delta'));
      expect(text, contains('event: message_delta'));
      expect(text, contains('event: message_stop'));

      // delta 事件带 text_delta
      final deltaLine = text
          .split('\n')
          .firstWhere((l) => l.startsWith('data: ') && l.contains('text_delta'));
      final deltaJson = jsonDecode(deltaLine.substring(6)) as Map<String, dynamic>;
      expect(deltaJson['delta']['type'], 'text_delta');
      expect(deltaJson['delta']['text'], isNotEmpty);
    });

    test('system 顶层字段被接受（不报 400）', () async {
      final (status, _, _) = await post('/v1/messages', {
        'model': 'qwen-test',
        'system': 'You are helpful.',
        'messages': [
          {'role': 'user', 'content': 'hi'}
        ],
      }, headers: {
        'x-api-key': apiKey,
      });
      expect(status, 200);
    });
  });

  group('模型列表', () {
    test('/v1/models 返回已安装模型', () async {
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/v1/models'),
      );
      req.headers.set('Authorization', 'Bearer $apiKey');
      final resp = await req.close();
      final text = await utf8.decoder.bind(resp).join();
      client.close();

      expect(resp.statusCode, 200);
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['object'], 'list');
      expect((json['data'] as List).length, 1);
      expect(json['data'][0]['id'], 'qwen-test');
    });
  });
}
