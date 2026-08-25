// lib/core/models/model_params.dart
// 每模型一套推理参数（需求文档 §4.1）
// 采样参数每次生成即时生效；上下文参数（n_ctx/n_threads）改动需重载模型
import 'dart:convert';

/// 模型推理参数（含范围校验与出厂默认值）
class ModelParams {
  // 采样参数（即时生效）
  final double temperature;
  final int topK;
  final double topP;
  final double repeatPenalty;
  final int maxTokens;

  // 上下文参数（改动需重载模型）
  final int nCtx;
  final int nThreads;

  // 系统提示词（即时生效，每模型可配）
  final String systemPrompt;

  // ---- 范围与默认值（需求文档 §4.1）----
  static const double minTemperature = 0.0, maxTemperature = 2.0, defTemperature = 0.7;
  static const int minTopK = 1, maxTopK = 100, defTopK = 40;
  static const double minTopP = 0.0, maxTopP = 1.0, defTopP = 0.9;
  static const double minRepeatPenalty = 1.0, maxRepeatPenalty = 2.0, defRepeatPenalty = 1.1;
  static const int minMaxTokens = 16, maxMaxTokens = 4096, defMaxTokens = 512;
  static const int minNCtx = 512, maxNCtx = 8192, defNCtx = 2048;
  static const int minNThreads = 1, maxNThreads = 8, defNThreads = 4;
  static const int maxSystemPromptLength = 2000;
  static const String defSystemPrompt =
      'You are a helpful AI assistant. Respond in Chinese.';

  const ModelParams({
    this.temperature = defTemperature,
    this.topK = defTopK,
    this.topP = defTopP,
    this.repeatPenalty = defRepeatPenalty,
    this.maxTokens = defMaxTokens,
    this.nCtx = defNCtx,
    this.nThreads = defNThreads,
    this.systemPrompt = defSystemPrompt,
  });

  static const ModelParams defaults = ModelParams();

  /// 解析持久化 JSON：逐字段容错 + 范围钳制（数据库脏数据不致崩溃）
  factory ModelParams.fromJson(Map<String, dynamic> json) {
    double clampD(num v, double min, double max, double def) {
      final d = v.toDouble();
      if (d.isNaN || d < min || d > max) return def;
      return d;
    }

    int clampI(dynamic v, int min, int max, int def) {
      if (v is! num) return def;
      final i = v.toInt();
      if (i < min || i > max) return def;
      return i;
    }

    final sp = json['systemPrompt'];
    return ModelParams(
      temperature: clampD(json['temperature'] ?? defTemperature, minTemperature, maxTemperature, defTemperature),
      topK: clampI(json['topK'], minTopK, maxTopK, defTopK),
      topP: clampD(json['topP'] ?? defTopP, minTopP, maxTopP, defTopP),
      repeatPenalty: clampD(json['repeatPenalty'] ?? defRepeatPenalty, minRepeatPenalty, maxRepeatPenalty, defRepeatPenalty),
      maxTokens: clampI(json['maxTokens'], minMaxTokens, maxMaxTokens, defMaxTokens),
      nCtx: clampI(json['nCtx'], minNCtx, maxNCtx, defNCtx),
      nThreads: clampI(json['nThreads'], minNThreads, maxNThreads, defNThreads),
      systemPrompt: sp is String && sp.length <= maxSystemPromptLength ? sp : defSystemPrompt,
    );
  }

  /// 是否与 [other] 的上下文参数一致（不一致则需重载模型才生效）
  bool sameContextSignature(ModelParams other) =>
      nCtx == other.nCtx && nThreads == other.nThreads;

  Map<String, dynamic> toJson() => {
        'temperature': temperature,
        'topK': topK,
        'topP': topP,
        'repeatPenalty': repeatPenalty,
        'maxTokens': maxTokens,
        'nCtx': nCtx,
        'nThreads': nThreads,
        'systemPrompt': systemPrompt,
      };

  String encode() => jsonEncode(toJson());
}
