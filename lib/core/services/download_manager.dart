// lib/core/services/download_manager.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下载任务状态（见技术设计 4.4 状态机）
enum DownloadStatus { queued, downloading, paused, verifying, completed, failed }

class DownloadTask {
  final String id;          // = savePath
  final String url;
  final String displayName;
  final String savePath;    // 最终 .gguf 路径
  final String? expectedSha256;

  int totalBytes;           // -1 = 未知
  int receivedBytes = 0;
  double speedBps = 0;
  DownloadStatus status = DownloadStatus.queued;
  String? error;
  DateTime? completedAt;

  int _retryCount = 0;
  CancelToken? _cancelToken;

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
              receiveTimeout: const Duration(minutes: 1),
              maxRedirects: 5,
            ));

  static final DownloadManager instance = DownloadManager();

  static const String _prefsKey = 'download_tasks';

  final Dio _dio;
  final Map<String, DownloadTask> _tasks = {};
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
      for (final e in (jsonDecode(raw) as List)) {
        final task = DownloadTask.fromJson(e as Map<String, dynamic>);
        if (task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.queued ||
            task.status == DownloadStatus.verifying) {
          task.status = DownloadStatus.paused;
        }
        if (await File(task.partPath).exists() ||
            await File(task.savePath).exists()) {
          _tasks[task.id] = task;
        }
      }
    } catch (_) {}
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
    if (existing != null && existing.status == DownloadStatus.completed) {
      return existing;
    }
    if (await File(savePath).exists()) {
      throw Exception('文件已存在，请先删除后重新下载');
    }
    final task = existing ??
        DownloadTask(
          id: savePath,
          url: url,
          displayName: displayName,
          savePath: savePath,
          totalBytes: totalBytes,
          expectedSha256: expectedSha256,
        );
    _tasks[task.id] = task;
    unawaited(_run(task));
    return task;
  }

  /// 暂停：取消当前请求，保留 .part
  Future<void> pause(String id) async {
    final task = _tasks[id];
    if (task == null || task.status != DownloadStatus.downloading) return;
    task._cancelToken?.cancel('用户暂停');
  }

  /// 恢复：Range 续传
  Future<void> resume(String id) async {
    final task = _tasks[id];
    if (task == null || task.status == DownloadStatus.completed) return;
    task._retryCount = 0;
    unawaited(_run(task));
  }

  /// 取消并删除 .part
  Future<void> cancel(String id) async {
    final task = _tasks[id];
    if (task == null) return;
    task._cancelToken?.cancel('用户取消');
    _tasks.remove(id);
    final part = File(task.partPath);
    if (await part.exists()) await part.delete();
    _persist();
    _events.add(task);
  }

  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    task.error = null;
    task.speedBps = 0;
    _emit(task);

    final partFile = File(task.partPath);
    int startByte = 0;
    if (await partFile.exists()) {
      startByte = await partFile.length();
    }

    task._cancelToken = CancelToken();
    IOSink? sink;
    try {
      final response = await _dio.get<ResponseBody>(
        task.url,
        cancelToken: task._cancelToken,
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

      sink = partFile.openWrite(mode: isResume ? FileMode.append : FileMode.write);
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
        if (actual != task.expectedSha256) {
          await partFile.delete();
          throw Exception('文件校验失败（SHA256 不匹配）');
        }
      }

      // 校验通过 → 原子重命名，杜绝半成品被识别为有效模型
      if (await File(task.savePath).exists()) {
        await File(task.savePath).delete();
      }
      await partFile.rename(task.savePath);
      task.status = DownloadStatus.completed;
      task.completedAt = DateTime.now();
      _emit(task);
    } on DioException catch (e) {
      await _closeSink(sink);
      if (CancelToken.isCancel(e)) {
        task.status = DownloadStatus.paused; // 用户暂停/取消
      } else {
        task._retryCount += 1;
        if (task._retryCount <= 3) {
          await Future.delayed(Duration(seconds: 2 * task._retryCount));
          return _run(task); // 网络重试（续传）
        }
        task.status = DownloadStatus.failed;
        task.error = '下载失败: ${e.message ?? e.type.name}';
      }
      _emit(task);
    } catch (e) {
      await _closeSink(sink);
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      _emit(task);
    } finally {
      _persist();
    }
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
