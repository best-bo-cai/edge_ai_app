// lib/core/services/download_manager.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下载任务状态（见技术设计 4.4 状态机）
enum DownloadStatus { queued, downloading, paused, verifying, completed, failed }

class DownloadTask {
  final String id;          // = savePath
  String url;
  final String displayName;
  final String savePath;    // 最终 .gguf 路径
  String? expectedSha256;

  int totalBytes;           // -1 = 未知
  int receivedBytes = 0;
  double speedBps = 0;
  DownloadStatus status = DownloadStatus.queued;
  String? error;
  DateTime? completedAt;

  int _retryCount = 0;
  CancelToken? _cancelToken;

  /// P1: _runLoop 防重入标志——start() 的状态检查与 resume() 的状态翻转
  /// 之间存在异步间隙（TOCTOU），并发调用会双开 _runLoop 双写 .part，
  /// 须以此标志保证同一任务同一时刻仅一个 _runLoop 在运行
  bool _isRunning = false;

  DownloadTask({
    required this.id,
    required this.url,
    required this.displayName,
    required this.savePath,
    required this.totalBytes,
    this.expectedSha256,
  });

  String get partPath => '$savePath.part';
  double get progress => totalBytes > 0 ? receivedBytes / totalBytes : 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'displayName': displayName,
        'savePath': savePath,
        'totalBytes': totalBytes,
        'expectedSha256': expectedSha256,
        'receivedBytes': receivedBytes,
        'status': status.name,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
        id: json['id'] as String,
        url: json['url'] as String,
        displayName: json['displayName'] as String,
        savePath: json['savePath'] as String,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? -1,
        expectedSha256: json['expectedSha256'] as String?,
      )
        ..receivedBytes = (json['receivedBytes'] as num?)?.toInt() ?? 0
        ..status = DownloadStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => DownloadStatus.paused,
        );
}

/// 可断点续传的下载管理器（应用内后台：切页不中断；杀进程后可续传）
class DownloadManager {
  DownloadManager({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              // 连接超时：死链/被墙域名 30s 内失败，及时进入重试/暂停流程
              connectTimeout: const Duration(seconds: 30),
              // 收包间超时：慢速大文件下载不被误杀
              receiveTimeout: const Duration(minutes: 1),
              maxRedirects: 5,
            ));

  static final DownloadManager instance = DownloadManager();

  static const String _prefsKey = 'download_tasks';

  final Dio _dio;
  final Map<String, DownloadTask> _tasks = {};

  /// 串行队列（技术设计：单任务串行省电）——同一时刻仅 1 个任务在下载，
  /// 后续任务置 queued 排队，前序结束（完成/暂停/失败/取消）后自动启动
  DownloadTask? _active;
  final List<DownloadTask> _queue = [];

  final StreamController<DownloadTask> _events =
      StreamController<DownloadTask>.broadcast();

  /// 任务变更事件流（进度/状态），UI 通过 id 过滤订阅
  Stream<DownloadTask> get events => _events.stream;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);
  DownloadTask? taskOf(String id) => _tasks[id];

  /// 启动时恢复任务记录；未完成且存在 .part 的任务标记为 paused
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final List<dynamic> records;
      try {
        records = jsonDecode(raw) as List;
      } catch (e) {
        debugPrint('[DownloadManager] 任务记录解析失败: $e');
        return;
      }
      for (final record in records) {
        try {
          final task = DownloadTask.fromJson(record as Map<String, dynamic>);
          if (task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued ||
              task.status == DownloadStatus.verifying) {
            task.status = DownloadStatus.paused;
          }
          if (await File(task.partPath).exists() ||
              await File(task.savePath).exists()) {
            _tasks[task.id] = task;
          }
        } catch (e) {
          // 单条记录损坏不影响其余任务恢复
          debugPrint('[DownloadManager] 恢复任务失败，已跳过: $e');
        }
      }
    } catch (e) {
      debugPrint('[DownloadManager] init 失败: $e');
    }
  }

  /// 开始（或继续）一个下载任务
  Future<DownloadTask> start({
    required String url,
    required String displayName,
    required String savePath,
    int totalBytes = -1,
    String? expectedSha256,
  }) async {
    final existing = _tasks[savePath];

    // C1: 任务已在下载/校验中直接返回，杜绝同任务并发双 _run 双写 .part
    if (existing != null &&
        (existing.status == DownloadStatus.downloading ||
            existing.status == DownloadStatus.verifying)) {
      return existing;
    }

    final fileExists = await File(savePath).exists();

    // completed 短路前先确认文件仍在，文件已丢失则重新下载
    if (existing != null &&
        existing.status == DownloadStatus.completed &&
        fileExists) {
      return existing;
    }
    if (fileExists) {
      throw Exception('文件已存在，请先删除后重新下载');
    }

    final DownloadTask task;
    if (existing != null) {
      // P4: 走到这里且状态为 completed，说明最终文件已丢失需重新下载，
      // 清空完成态数据，避免 _runLoop 启动前 UI 短暂显示旧完成进度/时间
      if (existing.status == DownloadStatus.completed) {
        existing.completedAt = null;
        existing.receivedBytes = 0;
      }
      // 已存在的非运行任务更新下载参数
      if (existing.url != url) {
        // 旧 .part 属于旧 url，不能续传复用
        existing.receivedBytes = 0;
        try {
          final stale = File(existing.partPath);
          if (await stale.exists()) await stale.delete();
        } catch (_) {}
      }
      existing.url = url;
      existing.expectedSha256 = expectedSha256;
      if (totalBytes > 0) existing.totalBytes = totalBytes;
      task = existing;
    } else {
      // P2: 新建任务时磁盘上已有的 .part 无法证明归属（可能是其他 url 的
      // 残留或损坏数据），一律删除，防止跨源续传拼出损坏文件
      try {
        final orphan = File('$savePath.part');
        if (await orphan.exists()) await orphan.delete();
      } catch (_) {}
      task = DownloadTask(
        id: savePath,
        url: url,
        displayName: displayName,
        savePath: savePath,
        totalBytes: totalBytes,
        expectedSha256: expectedSha256,
      );
    }
    task._retryCount = 0;
    _tasks[task.id] = task;
    unawaited(_run(task));
    return task;
  }

  /// 暂停：取消当前请求，保留 .part
  Future<void> pause(String id) async {
    final task = _tasks[id];
    if (task == null) return;
    if (task.status == DownloadStatus.queued) {
      _queue.remove(task);
      task.status = DownloadStatus.paused;
      _emit(task);
      return;
    }
    if (task.status != DownloadStatus.downloading) return;
    task._cancelToken?.cancel('用户暂停');
  }

  /// 恢复：Range 续传
  Future<void> resume(String id) async {
    final task = _tasks[id];
    if (task == null || task.status == DownloadStatus.completed) return;
    // C1: 下载/校验中不可重复启动；排队中无需重复入队
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.verifying ||
        task.status == DownloadStatus.queued) {
      return;
    }
    task._retryCount = 0;
    unawaited(_run(task));
  }

  /// 取消并删除 .part
  Future<void> cancel(String id) => _remove(id, reason: '用户取消');

  /// 清除指定路径的任务记录（本地模型文件被删除后联动调用）：
  /// 移除任务、取消运行中 token、删 .part、持久化，
  /// 避免残留的 completed 记录指向已删除文件导致详情页死锁
  Future<void> forget(String savePath) =>
      _remove(savePath, reason: '模型已删除');

  Future<void> _remove(String id, {required String reason}) async {
    final task = _tasks[id];
    if (task == null) return;
    task._cancelToken?.cancel(reason);
    _tasks.remove(id);
    _queue.remove(task);
    try {
      final part = File(task.partPath);
      if (await part.exists()) await part.delete();
    } catch (e) {
      // 删除失败不阻断流程
      debugPrint('[DownloadManager] 删除 .part 失败: $e');
    }
    _persist();
    _emit(task);
  }

  Future<void> _run(DownloadTask task) async {
    // 串行队列：已有任务在下载则置 queued 排队，由前序结束时自动启动
    if (_active != null && _active != task) {
      task.status = DownloadStatus.queued;
      _emit(task);
      if (!_queue.contains(task)) _queue.add(task);
      return;
    }
    // P1: 防重入——同步段原子检查置位。并发 start()+resume() 时后到者在
    // 此处直接返回（不进 try/finally，避免误清理 _active），彻底封死双开
    if (task._isRunning) return;
    task._isRunning = true;
    _active = task;
    try {
      await _runLoop(task);
    } finally {
      // P1: 复位须在 _startNextQueued 之前，杜绝唤醒队列时同任务再开
      task._isRunning = false;
      if (_active == task) {
        _active = null;
        _startNextQueued();
      }
    }
  }

  void _startNextQueued() {
    while (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      // 已取消或状态已变化的排队任务直接跳过
      if (_tasks[next.id] != next || next.status != DownloadStatus.queued) {
        continue;
      }
      unawaited(_run(next));
      return;
    }
  }

  Future<void> _runLoop(DownloadTask task) async {
    final cancelToken = CancelToken();
    task._cancelToken = cancelToken;

    while (true) {
      // 任务已被取消/移除时立即中止，防止已取消任务复活
      if (_tasks[task.id] != task) return;

      task.status = DownloadStatus.downloading;
      task.error = null;
      task.speedBps = 0;
      _emit(task);

      final partFile = File(task.partPath);
      int startByte = 0;
      if (await partFile.exists()) {
        startByte = await partFile.length();
      }

      IOSink? sink;
      try {
        final response = await _dio.get<ResponseBody>(
          task.url,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: startByte > 0 ? {'Range': 'bytes=$startByte-'} : null,
          ),
        );

        // 206 = 服务器接受续传；200 = 忽略 Range 需重写
        final isResume = response.statusCode == 206;
        final stream = response.data!.stream;

        if (isResume) {
          // content-range: bytes start-end/total
          final cr = response.headers.value(HttpHeaders.contentRangeHeader);
          final total = int.tryParse(cr?.split('/').last ?? '');
          if (total != null) task.totalBytes = total;
          task.receivedBytes = startByte;
        } else {
          final cl = response.headers.value(HttpHeaders.contentLengthHeader);
          final parsed = cl == null ? null : int.tryParse(cl);
          if (parsed != null && parsed > 0) task.totalBytes = parsed;
          task.receivedBytes = 0;
        }

        // 写文件前确保目录存在
        final dir = partFile.parent;
        if (!await dir.exists()) await dir.create(recursive: true);

        sink = partFile.openWrite(
            mode: isResume ? FileMode.append : FileMode.write);
        var lastEmitMs = DateTime.now().millisecondsSinceEpoch;
        var lastEmitBytes = task.receivedBytes;

        await for (final chunk in stream) {
          sink.add(chunk);
          task.receivedBytes += chunk.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastEmitMs >= 500) {
            final dt = (now - lastEmitMs) / 1000;
            final instant = (task.receivedBytes - lastEmitBytes) / dt;
            task.speedBps = task.speedBps == 0
                ? instant
                : task.speedBps * 0.6 + instant * 0.4; // EMA 平滑
            lastEmitMs = now;
            lastEmitBytes = task.receivedBytes;
            _emit(task);
          }
        }
        await sink.flush();
        await sink.close();
        sink = null;

        // 完整性校验（需求 2.4）
        if (task.expectedSha256 != null) {
          task.status = DownloadStatus.verifying;
          _emit(task);
          final actual = await sha256OfFile(task.partPath);
          // 校验耗时较长，期间任务可能已被取消（.part 已删除）
          if (_tasks[task.id] != task) return;
          if (actual != task.expectedSha256) {
            try {
              await partFile.delete();
            } catch (_) {}
            throw Exception('文件校验失败（SHA256 不匹配）');
          }
        }

        // 原子重命名前确认任务未被取消，杜绝已取消任务复活
        if (_tasks[task.id] != task) return;
        // 校验通过 → 原子重命名，杜绝半成品被识别为有效模型
        if (await File(task.savePath).exists()) {
          await File(task.savePath).delete();
        }
        await partFile.rename(task.savePath);
        task.status = DownloadStatus.completed;
        task.completedAt = DateTime.now();
        _emit(task);
        return;
      } on DioException catch (e) {
        await _closeSink(sink);
        if (CancelToken.isCancel(e)) {
          // cancel() 已移除任务并清理 .part，直接返回避免复活
          if (_tasks[task.id] != task) return;
          task.status = DownloadStatus.paused; // 用户暂停
          _emit(task);
          return;
        }
        task._retryCount += 1;
        if (task._retryCount <= 3) {
          // 重试等待期间响应暂停/取消，不再无条件递归
          final cancelled = await _delayUnlessCancelled(
              Duration(seconds: 2 * task._retryCount), cancelToken);
          if (_tasks[task.id] != task) return; // 等待期间被取消
          if (cancelled) {
            task.status = DownloadStatus.paused; // 等待期间被暂停
            _emit(task);
            return;
          }
          continue; // 网络重试（续传）
        }
        task.status = DownloadStatus.failed;
        task.error = '下载失败: ${e.message ?? e.type.name}';
        _emit(task);
        return;
      } catch (e) {
        await _closeSink(sink);
        // 校验期间被取消（.part 被删导致异常）不复活任务
        if (_tasks[task.id] != task) return;
        task.status = DownloadStatus.failed;
        task.error = e.toString();
        _emit(task);
        return;
      } finally {
        _persist();
      }
    }
  }

  /// 可被取消的延时：等待期间暂停/取消生效时提前返回 true
  Future<bool> _delayUnlessCancelled(Duration duration, CancelToken token) {
    final completer = Completer<bool>();
    Timer? timer;
    timer = Timer(duration, () {
      timer = null;
      if (!completer.isCompleted) completer.complete(false);
    });
    token.whenCancel.then((_) {
      timer?.cancel();
      if (!completer.isCompleted) completer.complete(true);
    });
    return completer.future;
  }

  void _emit(DownloadTask task) => _events.add(task);

  Future<void> _closeSink(IOSink? sink) async {
    try {
      await sink?.close();
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey, jsonEncode(_tasks.values.map((t) => t.toJson()).toList()));
    } catch (_) {}
  }

  /// 流式计算文件 SHA256（多 GB 文件不占内存）
  static Future<String> sha256OfFile(String path) async {
    final digest = await sha256.bind(File(path).openRead()).last;
    return digest.toString();
  }
}
