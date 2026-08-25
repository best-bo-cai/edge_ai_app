// lib/core/services/api_server/api_server_service.dart
// 本地大模型 API 服务（二期，需求文档 §5）：
// - HttpServer 绑定 127.0.0.1（ADR-0001：仅 loopback，不对局域网暴露）
// - 兼容 OpenAI /v1/chat/completions 与 Anthropic /v1/messages（均支持 SSE 流式）
// - API key 鉴权：Bearer（OpenAI 风格）与 x-api-key（Anthropic 风格）均接受
// - 模型严格匹配：请求的 model 未命中本地模型时返回 404（ADR-0002）
// - 推理经 InferenceScheduler 排队，与 App 内对话互斥，不打断进行中的生成
// - 完整请求/响应落 api_call_logs（需求文档 §5.6，含 token 统计）
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_database.dart';
import '../model_service.dart';
import 'inference_scheduler.dart';
import 'openai_handlers.dart';
import 'anthropic_handlers.dart';

/// 服务运行状态
enum ApiServerStatus { stopped, running, error }

/// API 服务（单例 ChangeNotifier：状态变化广播给设置页）
class ApiServerService extends ChangeNotifier {
  static final ApiServerService instance = ApiServerService._internal();
  ApiServerService._internal();

  static const String _prefEnabled = 'api_server_enabled';
  static const String _prefPort = 'api_server_port';
  static const String _prefApiKey = 'api_server_api_key';
  static const int defaultPort = 8080;

  /// 日志表单字段截断上限（防超大响应撑爆库）
  static const int _logFieldLimit = 4000;

  HttpServer? _server;
  ApiServerStatus _status = ApiServerStatus.stopped;
  String? _lastError;

  int _port = defaultPort;
  String _apiKey = '';

  /// 调用统计（进程内累计；明细见 api_call_logs 表）
  int _totalCalls = 0;
  int _failedCalls = 0;

  final ModelService _modelService = ModelService();
  final InferenceScheduler _scheduler = InferenceScheduler();

  ApiServerStatus get status => _status;
  String? get lastError => _lastError;
  int get port => _port;
  String get apiKey => _apiKey;
  bool get isRunning => _status == ApiServerStatus.running;
  int get totalCalls => _totalCalls;
  int get failedCalls => _failedCalls;
  String get baseUrl => 'http://127.0.0.1:$_port';

  /// App 启动时恢复：读取配置；若退出前服务开着则自动重启
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _port = prefs.getInt(_prefPort) ?? defaultPort;
    _apiKey = prefs.getString(_prefApiKey) ?? '';
    if (prefs.getBool(_prefEnabled) == true && _apiKey.isNotEmpty) {
      await start(autoRestart: true);
    }
  }

  Future<void> setPort(int port) async {
    if (isRunning) return; // 运行中不允许改端口，先停止服务
    _port = port;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefPort, port);
    notifyListeners();
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefApiKey, _apiKey);
    notifyListeners();
  }

  /// 启动服务。autoRestart=true 为开机自启场景（失败静默记录，不打扰用户）。
  Future<void> start({bool autoRestart = false}) async {
    if (isRunning) return;
    if (_apiKey.isEmpty) {
      _status = ApiServerStatus.error;
      _lastError = '请先设置 API Key';
      notifyListeners();
      return;
    }
    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4, // ADR-0001：仅本机访问
        _port,
      );
      _server!.listen(_handleConnection, onError: (e) {
        debugPrint('ApiServer listen error: $e');
      });
      _status = ApiServerStatus.running;
      _lastError = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefEnabled, true);
      debugPrint('ApiServer: listening on $baseUrl');
    } catch (e) {
      _status = ApiServerStatus.error;
      _lastError = '端口 $_port 绑定失败：$e';
      debugPrint('ApiServer start failed: $e');
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _status = ApiServerStatus.stopped;
    _lastError = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, false);
    notifyListeners();
  }

  // ---------- 连接处理 ----------

  Future<void> _handleConnection(HttpRequest request) async {
    _totalCalls++;
    final stopwatch = Stopwatch()..start();
    var statusCode = 500;
    var requestBody = '';
    var responseBody = '';
    String? modelId;
    int? promptTokens;
    int? outputTokens;

    try {
      // 鉴权（401 不透出模型信息）
      if (!_authorize(request)) {
        _failedCalls++;
        statusCode = 401;
        final resp = jsonEncode({
          'error': {'message': 'Invalid API key', 'type': 'authentication_error'},
        });
        await _writeJson(request, 401, resp);
        responseBody = resp;
        return;
      }

      // 请求体只读一次，handler 与日志共用
      requestBody = await utf8.decoder.bind(request).join();
      modelId = _extractModel(requestBody);
      final path = request.uri.path;

      switch (path) {
        case '/v1/models':
        case '/v1/models/':
          // 模型列表（两协议共用入口）
          await OpenAiHandlers.handleModels(request, _modelService.availableModels);
          statusCode = 200;
          responseBody = '(models list)';
          break;

        case '/v1/chat/completions':
          final outcome = await OpenAiHandlers.handleChatCompletions(
            request,
            requestBody,
            modelService: _modelService,
            scheduler: _scheduler,
          );
          statusCode = outcome.statusCode;
          responseBody = outcome.body;
          promptTokens = outcome.promptTokens;
          outputTokens = outcome.outputTokens;
          break;

        case '/v1/messages':
          final outcome = await AnthropicHandlers.handleMessages(
            request,
            requestBody,
            modelService: _modelService,
            scheduler: _scheduler,
          );
          statusCode = outcome.statusCode;
          responseBody = outcome.body;
          promptTokens = outcome.promptTokens;
          outputTokens = outcome.outputTokens;
          break;

        default:
          _failedCalls++;
          statusCode = 404;
          final resp = jsonEncode({
            'error': {'message': 'Not found: $path', 'type': 'invalid_request_error'},
          });
          await _writeJson(request, 404, resp);
          responseBody = resp;
          return;
      }

      if (statusCode >= 400) _failedCalls++;
    } catch (e) {
      _failedCalls++;
      debugPrint('ApiServer handler error: $e');
      statusCode = 500;
      try {
        final resp = jsonEncode({
          'error': {'message': 'Internal error', 'type': 'api_error'},
        });
        await _writeJson(request, 500, resp);
        responseBody = resp;
      } catch (_) {
        // 响应可能已提交（SSE 中途异常），无法补写
      }
    } finally {
      stopwatch.stop();
      await _logCall(
        endpoint: '${request.method} ${request.uri.path}',
        statusCode: statusCode,
        modelId: modelId,
        promptTokens: promptTokens,
        outputTokens: outputTokens,
        requestBody: requestBody,
        responseBody: responseBody,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      notifyListeners(); // 刷新设置页统计
    }
  }

  /// 鉴权：Bearer token（OpenAI 风格）或 x-api-key（Anthropic 风格）任一匹配
  bool _authorize(HttpRequest request) {
    if (_apiKey.isEmpty) return false;
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth != null &&
        auth.startsWith('Bearer ') &&
        auth.substring(7).trim() == _apiKey) {
      return true;
    }
    final xKey = request.headers.value('x-api-key');
    return xKey != null && xKey.trim() == _apiKey;
  }

  String? _extractModel(String body) {
    if (body.isEmpty) return null;
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) return json['model'] as String?;
    } catch (_) {}
    return null;
  }

  Future<void> _writeJson(HttpRequest request, int status, String body) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(body);
    await response.close();
  }

  /// 完整请求/响应落库（需求文档 §5.6：审计要求记录完整内容）
  Future<void> _logCall({
    required String endpoint,
    required int statusCode,
    required String? modelId,
    required int? promptTokens,
    required int? outputTokens,
    required String requestBody,
    required String responseBody,
    required int elapsedMs,
  }) async {
    try {
      final db = await AppDatabase().database;
      await db.insert('api_call_logs', {
        'id': 'log_${DateTime.now().microsecondsSinceEpoch}_$_totalCalls',
        'endpoint': endpoint,
        'model_id': modelId,
        'prompt_tokens': promptTokens,
        'output_tokens': outputTokens,
        // 硬约束：记录完整请求与响应内容（超长截断保底防库膨胀）
        'request_body': _truncate(requestBody),
        'response_body': _truncate(responseBody),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('ApiServer log insert failed: $e');
    }
  }

  static String _truncate(String s) =>
      s.length > _logFieldLimit ? '${s.substring(0, _logFieldLimit)}…' : s;
}

/// handler 统一返回结构：响应体（日志用）+ 状态码 + token 统计
class HandlerOutcome {
  final int statusCode;
  final String body;
  final int? promptTokens;
  final int? outputTokens;

  const HandlerOutcome(this.statusCode, this.body,
      {this.promptTokens, this.outputTokens});
}
