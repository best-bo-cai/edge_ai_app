// lib/core/services/api_server/inference_scheduler.dart
// 推理调度器：API 请求与 App 内对话共享同一 LlamaEngine，串行排队。
//
// 语义（二期需求文档 §5.4）：
// - 任一时刻只有一个推理在跑（App 内对话或 API 请求）
// - API 请求不打断进行中的生成；排队超时（120s）抛 TimeoutException → 429
// - 互斥通过 ChatService 的引擎锁实现（sendMessage 持同一把锁）
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chat_service.dart';
import '../model_params_service.dart';
import '../model_service.dart';
import '../../models/message.dart';

/// 一次 API 推理的结果（供 handler 组装响应与 usage 统计）
class ApiGenerationResult {
  final bool ok;
  final String content;
  final int promptTokens;
  final int outputTokens;
  final String error;

  const ApiGenerationResult({
    required this.ok,
    this.content = '',
    this.promptTokens = 0,
    this.outputTokens = 0,
    this.error = '',
  });
}

/// 流式片段回调
typedef TokenSink = void Function(String piece);

class InferenceScheduler {
  /// 排队等待超时
  static const Duration queueTimeout = Duration(seconds: 120);

  /// 提交一次推理任务：拿到引擎锁后加载模型并流式生成。
  /// [onToken] 逐段回调（SSE 转发）；返回聚合结果。
  Future<ApiGenerationResult> runGeneration({
    required String modelId,
    required List<MapEntry<String, String>> messages,
    TokenSink? onToken,
  }) async {
    final chatService = ChatService();
    final modelService = ModelService();

    final info = modelService.getModelInfo(modelId);
    if (info == null) {
      // 严格匹配兜底（handler 已预检 404）
      return ApiGenerationResult(ok: false, error: 'model not found: $modelId');
    }

    final queueStart = DateTime.now();

    // 借用 ChatService 公共推理通道（其内部走引擎锁 + 模型按需加载）
    // generateRaw 独立于会话时间线，无落库副作用
    final params = await ModelParamsService().getParams(modelId);
    final systemPrompt = messages
        .where((m) => m.key == 'system')
        .map((m) => m.value)
        .where((s) => s.trim().isNotEmpty)
        .followedBy([params.systemPrompt].where((s) => s.trim().isNotEmpty))
        .join('\n\n');

    final chatMessages = messages
        .where((m) => m.key == 'user' || m.key == 'assistant')
        .map((m) => ChatMessage(
              id: 'api_${DateTime.now().microsecondsSinceEpoch}_${m.hashCode}',
              content: m.value,
              role: m.key == 'user' ? MessageRole.user : MessageRole.assistant,
            ))
        .toList();
    if (chatMessages.isEmpty) {
      return const ApiGenerationResult(
          ok: false, error: 'no user/assistant messages in request');
    }

    final prompt = chatService.buildApiPrompt(systemPrompt, chatMessages);
    final promptTokens = chatService.estimateTokens(prompt);

    final buffer = StringBuffer();
    try {
      final stream = chatService.generateRaw(prompt, modelId: modelId);
      await for (final piece in stream) {
        buffer.write(piece);
        onToken?.call(piece);
      }
    } on Exception catch (e) {
      final waited = DateTime.now().difference(queueStart);
      debugPrint('ApiServer generation failed (${waited.inMilliseconds}ms): $e');
      return ApiGenerationResult(
        ok: false,
        error: 'generation failed: $e',
        promptTokens: promptTokens,
        outputTokens: chatService.estimateTokens(buffer.toString()),
      );
    }

    final content = buffer.toString();
    return ApiGenerationResult(
      ok: true,
      content: content,
      promptTokens: promptTokens,
      outputTokens: chatService.estimateTokens(content),
    );
  }
}
