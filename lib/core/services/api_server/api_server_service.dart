// lib/core/services/api_server/api_server_service.dart
// 本地大模型 API 服务（二期 §5 + 三期保活与局域网访问）：
// - HttpServer 绑定 0.0.0.0（ADR-0003：局域网开放，API key 为唯一防线）
// - 兼容 OpenAI /v1/chat/completions 与 Anthropic /v1/messages（均支持 SSE 流式）
// - API key 鉴权：Bearer（OpenAI 风格）与 x-api-key（Anthropic 风格）均接受
// - 模型严格匹配：请求的 model 未命中本地模型时返回 404（ADR-0002）
// - 推理经 InferenceScheduler 排队，与 App 内对话互斥，不打断进行中的生成
// - 完整请求/响应落 api_call_logs（含 token 统计与来源 IP）
// - 端口限制 49152~65535（动态端口段，默认 52415）；存量端口自动迁移
// - 接入地址：枚举全部非 loopback IPv4，WiFi > 热点 > VPN > 蜂窝 优先级排序
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;

import '../app_database.dart';
import '../model_service.dart';
import '../keepalive/keepalive_service.dart';
import 'inference_scheduler.dart';
import 'openai_handlers.dart';
import 'anthropic_handlers.dart';

/// 服务运行状态
enum ApiServerStatus { stopped, running, error }

/// 一条局域网接入地址（接口 IP + 网络类型标注）
class AccessAddress {
  final String ip;
  final String label; // WiFi / 热点 / VPN / 蜂窝
  final bool lanReachable; // 局域网设备是否可达（蜂窝=false，运营商 NAT）

  /// 排序优先级（WiFi 0 < 热点 1 < VPN 2 < 蜂窝 3 < 其他 4）
  int _priority = 4;

  AccessAddress(this.ip, this.label, {this.lanReachable = true});

  /// 调用方 SDK 的 base_url 值
  String get url => 'http://$ip:${ApiServerService.instance.port}/v1';
}

/// API 服务（单例 ChangeNotifier：状态变化广播给设置页）
class ApiServerService extends ChangeNotifier {
  static final ApiServerService instance = ApiServerService._internal();
  ApiServerService._internal();

  static const String _prefEnabled = 'api_server_enabled';
  static const String _prefPort = 'api_server_port';
  static const String _prefApiKey = 'api_server_api_key';

  /// 三期端口策略：IANA 动态/私有端口段（ADR-0003 对放弃 TLS 的部分补偿）
  static const int minPort = 49152;
  static const int maxPort = 65535;
  static const int defaultPort = 52415;

  /// 日志表单字段截断上限（防超大响应撑爆库）
  static const int _logFieldLimit = 4000;

  HttpServer? _server;
  ApiServerStatus _status = ApiServerStatus.stopped;
  String? _lastError;

  int _port = defaultPort;
  String _apiKey = '';

  /// 端口迁移一次性提示（init 时检测到存量端口越界置位，UI 消费后清除）
  bool _portMigrated = false;

  /// 当前接入地址列表（网络变化/页面刷新时重查）
  List<AccessAddress> _addresses = [];

  /// 调用统计（从 api_call_logs 表聚合，与日志页单一事实来源；失败口径：状态码 >= 400）
  int _totalCalls = 0;
  int _failedCalls = 0;

  /// 日志 id 自增序号（防同微秒并发落库主键冲突）
  int _logSeq = 0;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  final ModelService _modelService = ModelService();
  final InferenceScheduler _scheduler = InferenceScheduler();

  ApiServerStatus get status => _status;
  String? get lastError => _lastError;
  int get port => _port;
  String get apiKey => _apiKey;
  bool get isRunning => _status == ApiServerStatus.running;
  int get totalCalls => _totalCalls;
  int get failedCalls => _failedCalls;
  bool get portMigrated => _portMigrated;
  List<AccessAddress> get addresses => _addresses;
  String get baseUrl => 'http://127.0.0.1:$_port';

  /// App 启动时恢复：读取配置；若退出前服务开着则自动重启。
  /// 存量端口不在 49152~65535 内时自动迁移为默认端口（需求 §3.3）。
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_prefPort);
    if (saved == null) {
      _port = defaultPort;
    } else if (saved < minPort || saved > maxPort) {
      _port = defaultPort;
      _portMigrated = true;
      await prefs.setInt(_prefPort, _port);
      debugPrint('ApiServer: port $saved out of range, migrated to $_port');
    } else {
      _port = saved;
    }
    _apiKey = prefs.getString(_prefApiKey) ?? '';
    await refreshStats(); // 统计从日志表聚合（DB 为单一事实来源，重启不归零）
    await refreshAddresses();
    // 网络连通性变化 → 重查接入地址（IP 可能变化）。
    // try 保护单测环境（无插件实现时 MissingPluginException 不影响主流程）
    try {
      _connectivitySub ??= Connectivity().onConnectivityChanged.listen(
            (_) => refreshAddresses(),
            onError: (Object e) =>
                debugPrint('ApiServer connectivity watch error: $e'),
          );
    } catch (e) {
      debugPrint('ApiServer connectivity watch unavailable: $e');
    }
    if (prefs.getBool(_prefEnabled) == true && _apiKey.isNotEmpty) {
      await start();
    }
  }

  /// UI 消费迁移提示后清除
  void clearPortMigrated() {
    _portMigrated = false;
    notifyListeners();
  }

  Future<void> setPort(int port) async {
    if (isRunning) return; // 运行中不允许改端口，先停止服务
    _port = port;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefPort, port);
    await refreshAddresses(); // URL 含端口，同步刷新
    notifyListeners();
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefApiKey, _apiKey);
    notifyListeners();
  }

  /// 启动服务（含自动恢复场景：失败记录 lastError，由 UI 决定是否展示）。
  Future<void> start() async {
    if (isRunning) return;
    if (_apiKey.isEmpty) {
      _status = ApiServerStatus.error;
      _lastError = '请先设置 API Key';
      notifyListeners();
      return;
    }
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4, // ADR-0003：监听所有接口，局域网可访问
        _port,
      );
      _server!.listen(_handleConnection, onError: (e) {
        debugPrint('ApiServer listen error: $e');
      });
      _status = ApiServerStatus.running;
      _lastError = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefEnabled, true);
      debugPrint('ApiServer: listening on 0.0.0.0:$_port');
      // 前台服务保活（三期 §2）：与 HTTP 服务生命周期严格绑定。
      // - 用户开关/打开 App 场景：App 在前台，可正常拉起（打开 App 时
      //   init() 自动恢复路径同样在前台执行）
      // - Service 自愈的后台引擎场景：channel 未注册 → MissingPluginException
      //   被 KeepAliveService 捕获吞掉，此时 FGS 本就在运行，无需重复拉起
      final primary = _addresses.where((a) => a.lanReachable).firstOrNull;
      unawaited(KeepAliveService.startService(
        port: _port,
        address: primary?.ip ?? '127.0.0.1',
      ));
    } catch (e) {
      _status = ApiServerStatus.error;
      if (_isAddressInUse(e)) {
        _lastError = '端口 $_port 被占用，请停止服务后更换端口';
      } else {
        _lastError = '服务启动失败：$e';
      }
      debugPrint('ApiServer start failed: $e');
    }
    notifyListeners();
  }

  /// 端口占用判断：当前 Dart SDK 已移除 `AddressInUseException` 类型，
  /// 统一按 `SocketException` 的 errno 判断 EADDRINUSE
  /// （Linux/Android=98，macOS/iOS=48，Windows WSAEADDRINUSE=10048），
  /// osError 缺失时按消息兜底。
  static bool _isAddressInUse(Object e) {
    if (e is SocketException) {
      final code = e.osError?.errorCode;
      if (code == 98 || code == 48 || code == 10048) return true;
      final msg = e.message.toLowerCase();
      return msg.contains('eaddrinuse') ||
          msg.contains('address already in use');
    }
    return false;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _status = ApiServerStatus.stopped;
    _lastError = null;
    // 前台服务与 HTTP 服务生命周期严格绑定（三期 §2.1）
    await KeepAliveService.stopService();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, false);
    notifyListeners();
  }

  // ---------- 接入地址（三期 §3.2） ----------

  /// 枚举全部非 loopback IPv4 地址，按 WiFi > 热点 > VPN > 蜂窝 排序。
  /// 无任何可用地址（飞行模式等）时返回空列表，UI 兜底展示 127.0.0.1。
  Future<void> refreshAddresses() async {
    final list = <AccessAddress>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final nic in interfaces) {
        for (final addr in nic.addresses) {
          final (label, reachable, priority) = _classifyInterface(nic.name);
          list.add(AccessAddress(
            addr.address,
            label,
            lanReachable: reachable,
          ).._priority = priority);
        }
      }
    } catch (e) {
      debugPrint('ApiServer list interfaces failed: $e');
    }
    list.sort((a, b) => a._priority.compareTo(b._priority));
    _addresses = list;
    notifyListeners();
  }

  /// Android 网卡名启发式分类：wlan0=WiFi，ap0/swlan0/wlan1=热点，
  /// tun/tap=VPN，rmnet/ccmni=蜂窝（运营商 NAT，局域网不可达）。
  static (String, bool, int) _classifyInterface(String name) {
    final n = name.toLowerCase();
    if (n.startsWith('wlan0') || n.startsWith('eth')) {
      return ('WiFi', true, 0);
    }
    if (n.startsWith('ap') || n.startsWith('swlan') || n.startsWith('wlan')) {
      return ('热点', true, 1);
    }
    if (n.startsWith('tun') || n.startsWith('tap')) {
      return ('VPN', true, 2);
    }
    if (n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('usb')) {
      return ('蜂窝', false, 3);
    }
    return ('网络', true, 4);
  }

  // ---------- 连接处理 ----------

  Future<void> _handleConnection(HttpRequest request) async {
    final stopwatch = Stopwatch()..start();
    var statusCode = 500;
    var requestBody = '';
    var responseBody = '';
    String? modelId;
    int? promptTokens;
    int? outputTokens;
    final sourceIp = request.connectionInfo?.remoteAddress.address;

    try {
      // 鉴权（401 不透出模型信息）
      if (!_authorize(request)) {
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
          statusCode = 404;
          final resp = jsonEncode({
            'error': {'message': 'Not found: $path', 'type': 'invalid_request_error'},
          });
          await _writeJson(request, 404, resp);
          responseBody = resp;
          return;
      }

    } catch (e) {
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
        sourceIp: sourceIp,
      );
      await refreshStats(); // 统计与日志页同源（DB 聚合）
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

  /// 统计从日志表聚合（决策 2026-08-30：DB 为单一事实来源，与日志页严格一致；
  /// 失败口径与 HTTP 语义一致：状态码 >= 400。存量 NULL 视为未知，不计入失败）
  Future<void> refreshStats() async {
    try {
      final db = await AppDatabase().database;
      _totalCalls = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM api_call_logs')) ??
          0;
      _failedCalls = Sqflite.firstIntValue(await db.rawQuery(
              'SELECT COUNT(*) FROM api_call_logs WHERE status_code >= 400')) ??
          0;
    } catch (e) {
      debugPrint('ApiServer refresh stats failed: $e');
    }
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
    String? sourceIp,
  }) async {
    try {
      final db = await AppDatabase().database;
      await db.insert('api_call_logs', {
        'id': 'log_${DateTime.now().microsecondsSinceEpoch}_${_logSeq++}',
        'endpoint': endpoint,
        'model_id': modelId,
        'status_code': statusCode,
        'prompt_tokens': promptTokens,
        'output_tokens': outputTokens,
        // 硬约束：记录完整请求与响应内容（超长截断保底防库膨胀）
        'request_body': _truncate(requestBody),
        'response_body': _truncate(responseBody),
        'created_at': DateTime.now().millisecondsSinceEpoch,
        // 三期（ADR-0003）：局域网开放后记录调用来源，便于发现异常调用
        'source_ip': sourceIp,
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
