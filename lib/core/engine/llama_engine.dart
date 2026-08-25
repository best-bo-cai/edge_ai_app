// lib/core/engine/llama_engine.dart
// llama.cpp FFI 引擎封装：
// - 真实推理在独立 Isolate（工作线程）中执行，避免阻塞 UI
// - Token 通过 NativeCallable.listener 从任意线程回流到主 Isolate（流式）
// - 桌面/单测环境（无 libllama.so）自动降级为 Mock 输出
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ---------- C 函数签名 ----------

typedef _BackendInitC = Void Function();
typedef _BackendInitDart = void Function();

// 进度回调 C 签名（void 版；C++ 侧由 trampoline 适配 llama.cpp 的 bool 返回）
typedef _ProgressCallbackC = Void Function(Float progress, Pointer<Void> userData);

typedef _LoadModelC = Pointer<Void> Function(
    Pointer<Utf8> path, Int32 gpuLayers, Int32 useMmap,
    Pointer<NativeFunction<_ProgressCallbackC>> progressCb, Pointer<Void> progressData);
typedef _LoadModelDart = Pointer<Void> Function(
    Pointer<Utf8> path, int gpuLayers, int useMmap,
    Pointer<NativeFunction<_ProgressCallbackC>> progressCb, Pointer<Void> progressData);

typedef _StartContextC = Int32 Function(
    Pointer<Void> ectx, Int32 nCtx, Int32 nBatch, Int32 nThreads);
typedef _StartContextDart = int Function(
    Pointer<Void> ectx, int nCtx, int nBatch, int nThreads);

typedef _DecodeC = Int32 Function(
    Pointer<Void> ectx,
    Pointer<Utf8> prompt,
    Int32 maxTokens,
    Float topK,
    Float topP,
    Float temp,
    Float repeatPenalty,
    Pointer<NativeFunction<Void Function(Pointer<Utf8> piece, Pointer<Void> userData)>> callback,
    Pointer<Void> userData);
typedef _DecodeDart = int Function(
    Pointer<Void> ectx,
    Pointer<Utf8> prompt,
    int maxTokens,
    double topK,
    double topP,
    double temp,
    double repeatPenalty,
    Pointer<NativeFunction<Void Function(Pointer<Utf8> piece, Pointer<Void> userData)>> callback,
    Pointer<Void> userData);

typedef _AbortC = Void Function(Pointer<Void> ectx);
typedef _AbortDart = void Function(Pointer<Void> ectx);

// 释放 token 回调投递的堆拷贝（配合原生侧 strdup，listener 异步投递专用）
typedef _FreePieceC = Void Function(Pointer<Utf8> piece);
typedef _FreePieceDart = void Function(Pointer<Utf8> piece);

typedef _FreeC = Void Function(Pointer<Void> ectx);
typedef _FreeDart = void Function(Pointer<Void> ectx);

typedef _GetLastErrorC = Pointer<Utf8> Function();
typedef _GetLastErrorDart = Pointer<Utf8> Function();

typedef _TokenCallbackC = Void Function(Pointer<Utf8> piece, Pointer<Void> userData);

typedef _ModelDescC = Pointer<Utf8> Function(Pointer<Void> ectx);
typedef _ModelDescDart = Pointer<Utf8> Function(Pointer<Void> ectx);

typedef _ApplyTemplateC = Int32 Function(
    Pointer<Void> ectx,
    Pointer<Pointer<Utf8>> roles,
    Pointer<Pointer<Utf8>> contents,
    Int32 nMsg,
    Int32 addAss,
    Pointer<Utf8> outBuf,
    Int32 outSize);
typedef _ApplyTemplateDart = int Function(
    Pointer<Void> ectx,
    Pointer<Pointer<Utf8>> roles,
    Pointer<Pointer<Utf8>> contents,
    int nMsg,
    int addAss,
    Pointer<Utf8> outBuf,
    int outSize);

/// 供模板格式化的消息（role: system/user/assistant）
class TemplateMessage {
  final String role;
  final String content;
  const TemplateMessage(this.role, this.content);
}

/// 模型加载结果
class LoadModelResult {
  final bool ok;
  final String desc; // 模型描述（架构/量化）
  final String error;
  const LoadModelResult({required this.ok, this.desc = '', this.error = ''});
}

/// 一次推理的结局
enum GenerationOutcome { completed, aborted, failed }

/// llama.cpp 引擎（单例）。
///
/// 线程模型：
/// - loadModel/free 等命令发往工作 Isolate 执行（模型加载耗时数秒）
/// - decode 也在工作 Isolate 阻塞执行；token 回调经 NativeCallable.listener
///   直接投递到主 Isolate 事件循环，实现真实流式输出
/// - abort 从主 Isolate 直接调用（原生侧仅置原子标志，线程安全）
class LlamaEngine {
  static final LlamaEngine instance = LlamaEngine._internal();
  LlamaEngine._internal();

  // 桥接库名（native/CMakeLists.txt 产出 libedgellama.so；
  // 不能叫 libllama.so——与 llama.cpp 自身的共享库同名冲突）
  static const String _libName = 'libedgellama.so';

  bool _initialized = false;
  bool _isMock = true; // 无原生库时（桌面/单测）为 true
  int _ectxAddress = 0; // EdgeContext 指针地址（供 abort/模板调用）
  String _loadedPath = '';
  String _modelDesc = '';

  /// 当前加载所用的上下文签名（nCtx, nThreads）。
  /// 同路径但签名不同（参数配置改动）时 loadModel 强制重载。
  (int, int) _signature = (0, 0);

  Isolate? _worker;
  SendPort? _workerPort;
  Completer<void>? _workerReady;

  NativeCallable<_TokenCallbackC>? _tokenCallable;
  StreamController<String>? _genController;
  Completer<GenerationOutcome>? _genCompleter;

  // 加载请求：id 匹配（消息只能传基本类型，Completer 不能跨 Isolate 发送）
  int _nextLoadId = 0;
  final Map<int, Completer<Map<dynamic, dynamic>>> _pendingLoads = {};

  /// 模型加载进度（0.0~1.0），仅加载期间有事件
  final StreamController<double> _loadProgressController =
      StreamController<double>.broadcast();
  Stream<double> get loadProgress => _loadProgressController.stream;

  String get loadedPath => _loadedPath;
  String get modelDesc => _modelDesc;
  bool get isLoaded => _ectxAddress != 0;
  bool get isMock => _isMock;
  bool get isGenerating => _genCompleter != null && !_genCompleter!.isCompleted;

  /// 初始化：打开动态库并启动工作 Isolate。桌面环境自动进入 Mock 模式。
  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = true;

    if (!Platform.isAndroid && !Platform.isIOS) {
      debugPrint('LlamaEngine: 桌面环境，使用 Mock 引擎');
      return true; // _isMock 保持 true
    }

    try {
      // 主 Isolate 也持有一份符号（abort / getLastError 用）
      final lib = DynamicLibrary.open(_libName);
      _bindMainIsolateFunctions(lib);
      _isMock = false;

      // 启动工作 Isolate（承载耗时的加载与推理）
      _workerReady = Completer<void>();
      final ready = _workerReady!.future;
      final port = ReceivePort();
      _worker = await Isolate.spawn(_workerMain, port.sendPort,
          debugName: 'llama_worker');
      port.listen(_onWorkerMessage);
      await ready;
      debugPrint('LlamaEngine: 原生引擎就绪');
      return true;
    } catch (e) {
      debugPrint('LlamaEngine: 动态库加载失败，降级 Mock: $e');
      _isMock = true;
      return false;
    }
  }

  // ---------- 主 Isolate 直接绑定的符号（轻量调用） ----------

  _AbortDart? _abortFn;
  _ApplyTemplateDart? _applyTemplateFn;
  _FreePieceDart? _freePieceFn;

  void _bindMainIsolateFunctions(DynamicLibrary lib) {
    _abortFn = lib.lookupFunction<_AbortC, _AbortDart>('edge_llama_abort');
    _applyTemplateFn =
        lib.lookupFunction<_ApplyTemplateC, _ApplyTemplateDart>('edge_llama_apply_chat_template');
    _freePieceFn =
        lib.lookupFunction<_FreePieceC, _FreePieceDart>('edge_llama_free_piece');
  }

  /// 按模型自带聊天模板格式化消息（Qwen/Llama/Gemma 等各自模板自动适配）。
  /// 返回 null 表示不可用（Mock 模式/未加载/模板失败），调用方需自行兜底。
  String? applyChatTemplate(List<TemplateMessage> messages, {bool addAssistant = true}) {
    if (_isMock || !isLoaded || _applyTemplateFn == null) return null;
    if (messages.isEmpty) return null;

    final n = messages.length;
    final rolesP = calloc<Pointer<Utf8>>(n);
    final contentsP = calloc<Pointer<Utf8>>(n);
    try {
      for (var i = 0; i < n; i++) {
        rolesP[i] = messages[i].role.toNativeUtf8();
        contentsP[i] = messages[i].content.toNativeUtf8();
      }
      final ectx = Pointer<Void>.fromAddress(_ectxAddress);

      // 第一次调用探测所需缓冲大小
      final needed = _applyTemplateFn!(
          ectx, rolesP, contentsP, n, addAssistant ? 1 : 0, nullptr, 0);
      if (needed <= 0) return null;

      final outP = calloc<Uint8>(needed + 1).cast<Utf8>();
      try {
        final written = _applyTemplateFn!(
            ectx, rolesP, contentsP, n, addAssistant ? 1 : 0, outP, needed + 1);
        if (written < 0) return null;
        return outP.toDartString();
      } finally {
        calloc.free(outP);
      }
    } catch (e) {
      debugPrint('LlamaEngine.applyChatTemplate 失败: $e');
      return null;
    } finally {
      for (var i = 0; i < n; i++) {
        calloc.free(rolesP[i]);
        calloc.free(contentsP[i]);
      }
      calloc.free(rolesP);
      calloc.free(contentsP);
    }
  }

  // ---------- 加载 / 卸载 ----------

  /// 加载模型（在工作 Isolate 中执行）。
  /// 同一路径且上下文签名（nCtx/nThreads）一致时为幂等 no-op；
  /// 签名变化（参数配置改动）时强制重载。
  Future<LoadModelResult> loadModel({
    required String modelPath,
    int nCtx = 2048,
    int nBatch = 512,
    int nGpuLayers = 0,
    int nThreads = 0,
    bool useMmap = true,
  }) async {
    await initialize();
    if (_isMock) {
      _loadedPath = modelPath;
      _modelDesc = 'Mock Engine';
      return const LoadModelResult(ok: true, desc: 'Mock Engine');
    }
    if (isLoaded && _loadedPath == modelPath && _signature == (nCtx, nThreads)) {
      return LoadModelResult(ok: true, desc: _modelDesc);
    }

    // 注意：isolate 消息只能传基本类型/SendPort 等可发送对象，
    // Completer 不可发送（会抛 ArgumentError），用请求 id 匹配应答
    final id = _nextLoadId++;
    final reply = Completer<Map<dynamic, dynamic>>();
    _pendingLoads[id] = reply;
    _workerPort?.send({
      'cmd': 'load',
      'id': id,
      'path': modelPath,
      'nCtx': nCtx,
      'nBatch': nBatch,
      'nGpuLayers': nGpuLayers,
      'nThreads': nThreads,
      'useMmap': useMmap,
    });
    final r = await reply.future;
    if (r['ok'] == true) {
      _loadedPath = modelPath;
      _signature = (nCtx, nThreads);
      _modelDesc = r['desc'] as String? ?? '';
      _ectxAddress = r['ectx'] as int;
    }
    return LoadModelResult(
      ok: r['ok'] == true,
      desc: r['desc'] as String? ?? '',
      error: r['error'] as String? ?? '',
    );
  }

  /// 卸载当前模型（切换模型前调用）
  Future<void> unload() async {
    if (_isMock) {
      _loadedPath = '';
      _modelDesc = '';
      return;
    }
    if (!isLoaded) return;
    final ectx = _ectxAddress;
    _ectxAddress = 0;
    _loadedPath = '';
    _modelDesc = '';
    _signature = (0, 0);
    _workerPort?.send({'cmd': 'free', 'ectx': ectx});
  }

  // ---------- 推理 ----------

  /// 流式生成。prompt 为按模型模板格式化后的完整提示词。
  /// 采样参数（模型参数配置）随每次生成传入，即时生效。
  Stream<String> generate(
    String prompt, {
    int maxTokens = 512,
    double topK = 0,
    double topP = 0,
    double temperature = 0,
    double repeatPenalty = 0,
  }) {
    if (_genController != null && !_genController!.isClosed) {
      throw StateError('已有推理正在进行');
    }

    final controller = StreamController<String>.broadcast();
    final completer = Completer<GenerationOutcome>();
    _genController = controller;
    _genCompleter = completer;

    if (_isMock) {
      _mockGenerate(controller, completer);
      return controller.stream;
    }
    if (!isLoaded) {
      controller.addError(StateError('模型未加载'));
      completer.complete(GenerationOutcome.failed);
      scheduleMicrotask(controller.close);
      return controller.stream;
    }

    // NativeCallable：任意线程可调用，投递到主 Isolate 事件循环
    _tokenCallable ??=
        NativeCallable<_TokenCallbackC>.listener(_onNativeToken);
    _tokenCallable!.keepIsolateAlive = true;

    final ectx = _ectxAddress;
    final callbackPtr = _tokenCallable!.nativeFunction.address;

    _workerPort?.send({
      'cmd': 'decode',
      'ectx': ectx,
      'prompt': prompt,
      'maxTokens': maxTokens,
      'topK': topK,
      'topP': topP,
      'temp': temperature,
      'repeatPenalty': repeatPenalty,
      'callbackPtr': callbackPtr,
    });

    return controller.stream;
  }

  /// 当次 generate 的完成 Future（供需要等待结束的场景）
  Future<GenerationOutcome> get generationDone async =>
      _genCompleter?.future ?? Future.value(GenerationOutcome.completed);

  void _onNativeToken(Pointer<Utf8> piece, Pointer<Void> userData) {
    // 原生侧为异步投递做了堆拷贝：先读字符串，随即释放，避免泄漏
    final text = piece.toDartString();
    _freePieceFn?.call(piece);
    final c = _genController;
    if (c == null || c.isClosed) return;
    c.add(text);
  }

  /// 中止当前生成（线程安全：原生侧为原子标志位）
  void abort() {
    if (_isMock) return;
    if (_ectxAddress != 0) {
      _abortFn?.call(Pointer<Void>.fromAddress(_ectxAddress));
    }
  }

  Future<void> _mockGenerate(
      StreamController<String> controller, Completer<GenerationOutcome> completer) async {
    // Mock：模拟流式输出，保证桌面/单测链路可用
    const mockResponse = '这是 Mock 引擎的模拟回复。请在 Android 真机上使用模型广场下载模型，'
        '即可体验 llama.cpp 的本地离线推理。';
    try {
      for (var i = 0; i < mockResponse.length; i += 3) {
        if (controller.isClosed) break;
        controller.add(mockResponse.substring(
            i, i + 3 > mockResponse.length ? mockResponse.length : i + 3));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      completer.complete(GenerationOutcome.completed);
    } catch (_) {
      completer.complete(GenerationOutcome.failed);
    } finally {
      await controller.close();
    }
  }

  // ---------- 工作 Isolate 消息处理 ----------

  void _onWorkerMessage(dynamic msg) {
    if (msg is SendPort) {
      _workerPort = msg;
      _workerReady?.complete();
      return;
    }
    if (msg is Map<dynamic, dynamic>) {
      switch (msg['type']) {
        case 'loadResult':
          final reply = _pendingLoads.remove(msg['id']);
          reply?.complete(msg);
          break;
        case 'loadProgress':
          if (!_loadProgressController.isClosed) {
            _loadProgressController.add((msg['progress'] as num).toDouble());
          }
          break;
        case 'decodeDone':
          final outcome = switch (msg['result']) {
            0 => GenerationOutcome.completed,
            1 => GenerationOutcome.aborted,
            _ => GenerationOutcome.failed,
          };
          if (outcome == GenerationOutcome.failed) {
            final c = _genController;
            if (c != null && !c.isClosed && (msg['error'] as String?) != null) {
              c.addError(Exception(msg['error']));
            }
          }
          _genCompleter?.complete(outcome);
          _closeGeneration();
          break;
        case 'error':
          final c = _genController;
          if (c != null && !c.isClosed) {
            c.addError(Exception(msg['error'] ?? '未知错误'));
          }
          _genCompleter?.complete(GenerationOutcome.failed);
          _closeGeneration();
          break;
      }
    }
  }

  Future<void> _closeGeneration() async {
    _tokenCallable?.keepIsolateAlive = false;
    final c = _genController;
    _genController = null;
    _genCompleter = null;
    if (c != null && !c.isClosed) {
      await c.close();
    }
  }

  /// 释放全部资源（App 退出时）
  Future<void> dispose() async {
    await _closeGeneration();
    await unload();
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _workerPort = null;
    _tokenCallable?.close();
    _tokenCallable = null;
    _loadProgressController.close();
    _initialized = false;
  }

  // ---------- 工作 Isolate 入口 ----------

  static Future<void> _workerMain(SendPort mainPort) async {
    final port = ReceivePort();
    mainPort.send(port.sendPort);

    // 进度上报节流状态（单加载任务串行，一个变量即可）
    double lastSentProgress = -1.0;

    final lib = DynamicLibrary.open(_libName);
    final backendInit = lib.lookupFunction<_BackendInitC, _BackendInitDart>('edge_llama_backend_init');
    final loadModelFn = lib.lookupFunction<_LoadModelC, _LoadModelDart>('edge_llama_load_model');
    final startContextFn =
        lib.lookupFunction<_StartContextC, _StartContextDart>('edge_llama_start_context');
    final decodeFn = lib.lookupFunction<_DecodeC, _DecodeDart>('edge_llama_decode');
    final freeFn = lib.lookupFunction<_FreeC, _FreeDart>('edge_llama_free_context');
    final getLastErrorFn =
        lib.lookupFunction<_GetLastErrorC, _GetLastErrorDart>('edge_llama_get_last_error');

    backendInit();

    await for (final msg in port) {
      if (msg is! Map) continue;
      switch (msg['cmd']) {
        case 'load':
          final reqId = msg['id'] as int;
          final pathP = (msg['path'] as String).toNativeUtf8();

          // 进度回调：原生线程触发 → listener 投递到本 Isolate 事件循环 → 转发主 Isolate
          // 节流：进度变化 >= 1% 才发送，避免消息风暴
          final progressCb = NativeCallable<_ProgressCallbackC>.listener(
              (double progress, Pointer<Void> _) {
            if (progress - lastSentProgress >= 0.01 ||
                (progress >= 1.0 && lastSentProgress < 1.0)) {
              lastSentProgress = progress;
              mainPort.send({'type': 'loadProgress', 'id': reqId, 'progress': progress});
            }
          });

          final ectx = loadModelFn(
              pathP,
              msg['nGpuLayers'] as int,
              (msg['useMmap'] as bool) ? 1 : 0,
              progressCb.nativeFunction,
              nullptr);
          progressCb.close();
          calloc.free(pathP);
          if (ectx == nullptr) {
            final errP = getLastErrorFn();
            mainPort.send({'type': 'loadResult', 'id': reqId, 'ok': false, 'error': errP.toDartString()});
            continue;
          }
          final rc = startContextFn(
              ectx, msg['nCtx'] as int, msg['nBatch'] as int, msg['nThreads'] as int? ?? 0);
          if (rc != 0) {
            final errP = getLastErrorFn();
            mainPort.send({'type': 'loadResult', 'id': reqId, 'ok': false, 'error': errP.toDartString()});
            freeFn(ectx);
            continue;
          }
          mainPort.send({
            'type': 'loadResult',
            'id': reqId,
            'ok': true,
            'ectx': ectx.address,
            'desc': _modelDescOf(lib, ectx),
          });
          // 注意：ectx 生命周期由引擎持有，free 由 'free' 命令触发
          // （此处不能释放——闭包捕获地址即可，对象由 free 命令管理）
          break;

        case 'decode':
          final ectx = Pointer<Void>.fromAddress(msg['ectx'] as int);
          final promptP = (msg['prompt'] as String).toNativeUtf8();
          final callbackPtr = Pointer<NativeFunction<_TokenCallbackC>>.fromAddress(
              msg['callbackPtr'] as int);
          final result = decodeFn(
              ectx,
              promptP,
              msg['maxTokens'] as int,
              (msg['topK'] as num?)?.toDouble() ?? 0,
              (msg['topP'] as num?)?.toDouble() ?? 0,
              (msg['temp'] as num?)?.toDouble() ?? 0,
              (msg['repeatPenalty'] as num?)?.toDouble() ?? 0,
              callbackPtr,
              nullptr);
          calloc.free(promptP);
          if (result < 0) {
            final errP = getLastErrorFn();
            mainPort.send({'type': 'decodeDone', 'result': result, 'error': errP.toDartString()});
          } else {
            mainPort.send({'type': 'decodeDone', 'result': result});
          }
          break;

        case 'free':
          freeFn(Pointer<Void>.fromAddress(msg['ectx'] as int));
          break;
      }
    }
  }

  /// 读取模型描述（工作 Isolate 内调用）
  static String _modelDescOf(DynamicLibrary lib, Pointer<Void> ectx) {
    final descFn = lib.lookupFunction<_ModelDescC, _ModelDescDart>('edge_llama_model_desc');
    return descFn(ectx).toDartString();
  }
}
