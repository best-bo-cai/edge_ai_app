// lib/core/services/api_server/openai_handlers.dart
// OpenAI 兼容端点（二期需求 §5.2）：
// - GET  /v1/models                模型列表
// - POST /v1/chat/completions      对话补全（stream=true 走 SSE）
//
// 协议要点：
// - 模型严格匹配（ADR-0002）：model 未命中 → 404
// - stream=true：SSE data: 块逐 token 转发，末尾 data: [DONE]
// - 非 stream：一次性 JSON（含 usage）
// - 错误体格式对齐 OpenAI：{"error": {"message", "type", "code"}}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model_service.dart';
import 'api_server_service.dart' show HandlerOutcome;
import 'inference_scheduler.dart';

class OpenAiHandlers {
  /// GET /v1/models —— 供客户端发现可用模型（id 即请求时的 model 值）
  static Future<void> handleModels(HttpRequest request, List<ModelInfo> models) async {
    final response = request.response;
    response.statusCode = 200;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({
      'object': 'list',
      'data': models
          .map((m) => {
                'id': m.id,
                'object': 'model',
                'owned_by': 'edge_ai_app',
                'created': m.downloadDate?.millisecondsSinceEpoch ?? 0,
              })
          .toList(),
    }));
    await response.close();
  }

  /// POST /v1/chat/completions
  /// 返回 HandlerOutcome（响应体供调用日志落库）
  static Future<HandlerOutcome> handleChatCompletions(
    HttpRequest request,
    String body, {
    required ModelService modelService,
    required InferenceScheduler scheduler,
  }) async {
    // 1. 解析请求
    Map<String, dynamic> req;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) throw const FormatException('body not object');
      req = decoded;
    } on FormatException {
      return _error(request, 400, '请求体不是合法 JSON 对象', 'invalid_request_error');
    }

    final model = req['model'];
    if (model is! String || model.isEmpty) {
      return _error(request, 400, '缺少必填字段: model', 'invalid_request_error');
    }

    // 2. 模型严格匹配（ADR-0002）
    final info = modelService.getModelInfo(model);
    if (info == null) {
      return _error(
        request,
        404,
        'The model `$model` does not exist',
        'invalid_request_error',
        code: 'model_not_found',
      );
    }

    final messages = req['messages'];
    if (messages is! List || messages.isEmpty) {
      return _error(request, 400, '缺少必填字段: messages', 'invalid_request_error');
    }
    final parsed = <MapEntry<String, String>>[];
    for (final m in messages) {
      if (m is! Map<String, dynamic>) continue;
      final role = m['role'];
      final content = m['content'];
      if (role is! String || content is! String) continue;
      parsed.add(MapEntry(role, content));
    }
    if (parsed.isEmpty) {
      return _error(request, 400, 'messages 无有效条目', 'invalid_request_error');
    }

    final stream = req['stream'] == true;
    final id = 'chatcmpl-${DateTime.now().millisecondsSinceEpoch}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // 3. 推理（经调度器排队）
    try {
      if (stream) {
        return await _streamResponse(
          request, scheduler, model, id, created, parsed,
        );
      } else {
        final result = await scheduler.runGeneration(
          modelId: model,
          messages: parsed,
        );
        if (!result.ok) {
          return _error(request, 500, result.error, 'api_error');
        }
        final resp = jsonEncode({
          'id': id,
          'object': 'chat.completion',
          'created': created,
          'model': model,
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': result.content},
              'finish_reason': 'stop',
            }
          ],
          'usage': {
            'prompt_tokens': result.promptTokens,
            'completion_tokens': result.outputTokens,
            'total_tokens': result.promptTokens + result.outputTokens,
          },
        });
        final response = request.response;
        response.statusCode = 200;
        response.headers.contentType = ContentType.json;
        response.write(resp);
        await response.close();
        return HandlerOutcome(200, resp,
            promptTokens: result.promptTokens,
            outputTokens: result.outputTokens);
      }
    } on TimeoutException {
      return _error(request, 429, '引擎忙，排队超时', 'rate_limit_error');
    } on Exception catch (e) {
      return _error(request, 500, '推理失败: $e', 'api_error');
    }
  }

  /// SSE 流式响应：chunk 格式对齐 OpenAI
  static Future<HandlerOutcome> _streamResponse(
    HttpRequest request,
    InferenceScheduler scheduler,
    String model,
    String id,
    int created,
    List<MapEntry<String, String>> messages,
  ) async {
    final response = request.response;
    response.statusCode = 200;
    // charset 必须显式声明：无 charset 时 HttpResponse.write(String) 走 latin-1，
    // 中文 token 会抛 "Contains invalid characters" 导致流中断
    response.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8');
    response.headers.set('Cache-Control', 'no-cache');
    response.bufferOutput = false;

    final chunks = <String>[];

    // 发送队列：onToken 可能高频同步触发，写响应流必须串行
    // （flush 期间再次 write 会抛 StreamSink is bound to a stream）
    final queue = StreamController<Map<String, dynamic>>();
    final drained = () async {
      await for (final data in queue.stream) {
        final line = 'data: ${jsonEncode(data)}\n\n';
        chunks.add(line);
        // 字节写入绕过字符串编码器，彻底规避 latin-1 默认编码问题
        response.add(utf8.encode(line));
        await response.flush();
      }
    }();

    try {
      final result = await scheduler.runGeneration(
        modelId: model,
        messages: messages,
        onToken: (piece) => queue.add({
          // token 粒度 chunk（与 OpenAI 一致的增量 delta 结构）
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': model,
          'choices': [
            {
              'index': 0,
              'delta': {'content': piece},
              'finish_reason': null,
            }
          ],
        }),
      );

      if (!result.ok) {
        // 流已开始（200 已发），只能以错误 chunk 告终
        queue.add({
          'error': {'message': result.error, 'type': 'api_error'},
        });
      } else {
        // 收尾 chunk：finish_reason=stop + usage
        queue.add({
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': model,
          'choices': [
            {
              'index': 0,
              'delta': {},
              'finish_reason': 'stop',
            }
          ],
          'usage': {
            'prompt_tokens': result.promptTokens,
            'completion_tokens': result.outputTokens,
            'total_tokens': result.promptTokens + result.outputTokens,
          },
        });
      }
      await queue.close();
      await drained;

      response.add(utf8.encode('data: [DONE]\n\n'));
      await response.flush();
      await response.close();
      return HandlerOutcome(result.ok ? 200 : 500, chunks.join(),
          promptTokens: result.ok ? result.promptTokens : null,
          outputTokens: result.ok ? result.outputTokens : null);
    } catch (e) {
      // runGeneration 异常：尽量收尾，避免连接悬挂
      try {
        await queue.close();
        await drained;
        response.add(utf8.encode('data: [DONE]\n\n'));
        await response.flush();
        await response.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// OpenAI 风格错误响应
  static Future<HandlerOutcome> _error(
    HttpRequest request,
    int status,
    String message,
    String type, {
    String? code,
  }) async {
    final resp = jsonEncode({
      'error': {
        'message': message,
        'type': type,
        if (code != null) 'code': code,
      },
    });
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(resp);
    await response.close();
    return HandlerOutcome(status, resp);
  }
}
