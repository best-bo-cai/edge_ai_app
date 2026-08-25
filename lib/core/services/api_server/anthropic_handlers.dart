// lib/core/services/api_server/anthropic_handlers.dart
// Anthropic 兼容端点（二期需求 §5.3）：
// - POST /v1/messages   消息生成（stream=true 走 SSE）
//
// 与 OpenAI 的协议差异：
// - system 是请求顶层字段（不在 messages 数组内）
// - SSE 事件流：message_start → content_block_delta* →
//   message_delta(stop_reason+usage) → message_stop
// - 错误体：{"type": "error", "error": {"type", "message"}}
// - 鉴权支持 x-api-key 头（服务层已统一处理）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model_service.dart';
import 'api_server_service.dart' show HandlerOutcome;
import 'inference_scheduler.dart';

class AnthropicHandlers {
  /// POST /v1/messages
  /// 返回 HandlerOutcome（响应体供调用日志落库）
  static Future<HandlerOutcome> handleMessages(
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
      return _error(request, 400, 'invalid_request_error', '请求体不是合法 JSON 对象');
    }

    final model = req['model'];
    if (model is! String || model.isEmpty) {
      return _error(request, 400, 'invalid_request_error', '缺少必填字段: model');
    }

    // 2. 模型严格匹配（ADR-0002：未命中返回 404）
    final info = modelService.getModelInfo(model);
    if (info == null) {
      return _error(
        request,
        404,
        'not_found_error',
        'model not found: $model',
      );
    }

    final messages = req['messages'];
    if (messages is! List || messages.isEmpty) {
      return _error(request, 400, 'invalid_request_error', '缺少必填字段: messages');
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
      return _error(request, 400, 'invalid_request_error', 'messages 无有效条目');
    }

    // system 顶层字段（Anthropic 特有），有值则置于消息序列最前
    final system = req['system'];
    if (system is String && system.trim().isNotEmpty) {
      parsed.insert(0, MapEntry('system', system));
    }

    final stream = req['stream'] == true;
    final messageId = 'msg_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

    try {
      if (stream) {
        return await _streamResponse(request, scheduler, model, messageId, parsed);
      } else {
        final result = await scheduler.runGeneration(modelId: model, messages: parsed);
        if (!result.ok) {
          return _error(request, 500, 'api_error', result.error);
        }
        final resp = jsonEncode({
          'id': messageId,
          'type': 'message',
          'role': 'assistant',
          'model': model,
          'content': [
            {'type': 'text', 'text': result.content}
          ],
          'stop_reason': 'end_turn',
          'stop_sequence': null,
          'usage': {
            'input_tokens': result.promptTokens,
            'output_tokens': result.outputTokens,
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
      return _error(request, 429, 'rate_limit_error', '引擎忙，排队超时');
    } on Exception catch (e) {
      return _error(request, 500, 'api_error', '推理失败: $e');
    }
  }

  /// Anthropic SSE 事件流
  static Future<HandlerOutcome> _streamResponse(
    HttpRequest request,
    InferenceScheduler scheduler,
    String model,
    String messageId,
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

    // 发送队列：onToken 高频触发时写响应流必须串行
    // （flush 期间再次 write 会抛 StreamSink is bound to a stream）
    final queue = StreamController<MapEntry<String, Object>>();
    final drained = () async {
      await for (final event in queue.stream) {
        final line = 'event: ${event.key}\ndata: ${jsonEncode(event.value)}\n\n';
        chunks.add(line);
        // 字节写入绕过字符串编码器，彻底规避 latin-1 默认编码问题
        response.add(utf8.encode(line));
        await response.flush();
      }
    }();

    try {
      // message_start：携带消息元数据
      queue.add(MapEntry('message_start', {
        'type': 'message_start',
        'message': {
          'id': messageId,
          'type': 'message',
          'role': 'assistant',
          'model': model,
          'content': [],
          'stop_reason': null,
          'usage': {'input_tokens': 0, 'output_tokens': 0},
        },
      }));

      final result = await scheduler.runGeneration(
        modelId: model,
        messages: messages,
        onToken: (piece) => queue.add(MapEntry('content_block_delta', {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': piece},
            })),
      );

      if (result.ok) {
        // message_delta：stop_reason + usage
        queue.add(MapEntry('message_delta', {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
          'usage': {'output_tokens': result.outputTokens},
        }));
        queue.add(const MapEntry('message_stop', {'type': 'message_stop'}));
      } else {
        // 流已开始，以 error 事件告终（客户端 SDK 会识别）
        queue.add(MapEntry('error', {
          'type': 'error',
          'error': {'type': 'api_error', 'message': result.error},
        }));
      }

      await queue.close();
      await drained;
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
        await response.flush();
        await response.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// Anthropic 风格错误响应
  static Future<HandlerOutcome> _error(
    HttpRequest request,
    int status,
    String type,
    String message,
  ) async {
    final resp = jsonEncode({
      'type': 'error',
      'error': {'type': type, 'message': message},
    });
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(resp);
    await response.close();
    return HandlerOutcome(status, resp);
  }
}
