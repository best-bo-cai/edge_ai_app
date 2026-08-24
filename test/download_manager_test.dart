// test/download_manager_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:edge_ai_app/core/services/download_manager.dart';

/// 支持 Range 的内存文件服务（模拟 HF CDN）。
/// 可选：按 URL 映射不同内容、发送 N 字节后挂起（测暂停/取消）、
/// 发送 N 字节后流中抛网络错误（测中途失败续传）。
class FakeRangeServer implements HttpClientAdapter {
  FakeRangeServer(
    this.bytes, {
    this.failFirstTimes = 0,
    this.hangAfterBytes,
    this.failAfterBytes,
    Map<String, List<int>>? files,
  }) : files = files ?? {};

  final List<int> bytes; // 未命中 files 时的默认内容
  final Map<String, List<int>> files; // url -> 内容
  int failFirstTimes;
  int? hangAfterBytes; // 首次请求发送该字节数后挂起，直到请求被取消
  int? failAfterBytes; // 首次请求发送该字节数后流中抛网络错误

  final List<String> ranges = [];
  final List<String> requested = [];
  final List<String> log = []; // 'start:<url>' / 'end:<url>'，串行测试用
  bool _hungOnce = false;
  bool _failedOnce = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    final data = files[url] ?? bytes;
    if (failFirstTimes > 0) {
      failFirstTimes--;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    }
    final range = options.headers['Range'] as String?;
    ranges.add(range ?? 'none');
    requested.add(url);
    log.add('start:$url');

    var chunkData = data;
    var status = 200;
    final headers = <String, List<String>>{};
    if (range != null) {
      final start = int.parse(range.replaceAll(RegExp(r'[^0-9]'), ''));
      chunkData = data.sublist(start);
      status = 206;
      headers[HttpHeaders.contentRangeHeader] = [
        'bytes $start-${data.length - 1}/${data.length}'
      ];
    }
    headers[HttpHeaders.contentLengthHeader] = ['${chunkData.length}'];
    return ResponseBody(
      _stream(options, chunkData, url, cancelFuture),
      status,
      headers: headers,
    );
  }

  Stream<Uint8List> _stream(
    RequestOptions options,
    List<int> data,
    String url,
    Future<void>? cancelFuture,
  ) async* {
    const chunkSize = 100;
    var sent = 0;
    try {
      for (var i = 0; i < data.length; i += chunkSize) {
        final chunk = data.sublist(i, (i + chunkSize).clamp(0, data.length));
        yield Uint8List.fromList(chunk);
        sent += chunk.length;
        if (failAfterBytes != null &&
            !_failedOnce &&
            sent >= failAfterBytes!) {
          _failedOnce = true;
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          );
        }
        if (hangAfterBytes != null && !_hungOnce && sent >= hangAfterBytes!) {
          _hungOnce = true;
          // 挂起直到请求被取消（dio 会 cancel 上游订阅并完成 cancelFuture）
          await (cancelFuture ?? Completer<void>().future);
          return;
        }
      }
    } finally {
      log.add('end:$url');
    }
  }

  @override
  void close({bool force = false}) {}
}

/// 轮询等待条件成立（带超时保护）
Future<void> waitUntil(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmpDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('dl_test');
  });
  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  test('完整下载：写 .part → 校验 → 原子重命名', () async {
    final bytes = List<int>.generate(1000, (i) => i % 256);
    final savePath = '${tmpDir.path}/model.gguf';
    final server = FakeRangeServer(bytes);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final done = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.completed);
    await dm.start(
      url: 'https://example.com/model.gguf',
      displayName: 'model',
      savePath: savePath,
      expectedSha256: sha256.convert(bytes).toString(),
    );
    final task = await done.timeout(const Duration(seconds: 10));

    expect(server.ranges.single, 'none'); // 全新下载不带 Range
    expect(await File(savePath).readAsBytes(), bytes);
    expect(task.receivedBytes, 1000);
    expect(await File('$savePath.part').exists(), false);
  });

  test('断点续传：已有 .part 时发送 Range 并追加写', () async {
    final bytes = List<int>.generate(1000, (i) => i % 256);
    final savePath = '${tmpDir.path}/model.gguf';
    await File('$savePath.part').writeAsBytes(bytes.sublist(0, 400));
    final server = FakeRangeServer(bytes);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final done = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.completed);
    await dm.start(
        url: 'https://example.com/model.gguf',
        displayName: 'model',
        savePath: savePath);
    final task = await done.timeout(const Duration(seconds: 10));

    expect(server.ranges.single, 'bytes=400-');
    expect(await File(savePath).readAsBytes(), bytes);
    expect(task.totalBytes, 1000);
  });

  test('SHA256 不匹配：删除 .part 并置 failed', () async {
    final bytes = List<int>.generate(500, (i) => i % 256);
    final savePath = '${tmpDir.path}/model.gguf';
    final dm = DownloadManager(
        dio: Dio()..httpClientAdapter = FakeRangeServer(bytes));

    final failed = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.failed);
    await dm.start(
      url: 'https://example.com/model.gguf',
      displayName: 'model',
      savePath: savePath,
      expectedSha256: 'deadbeef',
    );
    final task = await failed.timeout(const Duration(seconds: 10));

    expect(task.error, contains('校验失败'));
    expect(await File('$savePath.part').exists(), false);
    expect(await File(savePath).exists(), false);
  });

  test('网络失败自动重试（保留字节续传）', () async {
    final bytes = List<int>.generate(300, (i) => i % 256);
    final savePath = '${tmpDir.path}/model.gguf';
    final server = FakeRangeServer(bytes, failFirstTimes: 1);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final done = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.completed);
    await dm.start(
        url: 'https://example.com/model.gguf',
        displayName: 'model',
        savePath: savePath);
    await done.timeout(const Duration(seconds: 15));

    expect(server.ranges, ['none']); // 重试仍是全新请求（首次即失败无字节）
    expect(await File(savePath).readAsBytes(), bytes);
  });

  test('下载中途失败：自动重试携带 Range 续传', () async {
    final bytes = List<int>.generate(1000, (i) => i % 256);
    final savePath = '${tmpDir.path}/model.gguf';
    final server = FakeRangeServer(bytes, failAfterBytes: 400);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final done = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.completed);
    await dm.start(
        url: 'https://example.com/model.gguf',
        displayName: 'model',
        savePath: savePath);
    await done.timeout(const Duration(seconds: 15));

    // 第二次请求从已落盘的 400 字节处续传
    expect(server.ranges, ['none', 'bytes=400-']);
    expect(await File(savePath).readAsBytes(), bytes);
  });

  test('暂停→恢复：保留 .part，恢复发 Range 续传', () async {
    final bytes = List<int>.generate(1000, (i) => i % 251);
    final savePath = '${tmpDir.path}/model.gguf';
    const url = 'https://example.com/model.gguf';
    final server = FakeRangeServer(bytes, hangAfterBytes: 400);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final paused = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.paused);
    final task = await dm.start(
        url: url, displayName: 'model', savePath: savePath);
    expect(task.status, DownloadStatus.downloading);

    // 等待已接收 400 字节（服务端挂起点）
    await waitUntil(() => task.receivedBytes >= 400);
    await dm.pause(savePath);
    await paused.timeout(const Duration(seconds: 10));

    expect(task.status, DownloadStatus.paused);
    expect(await File('$savePath.part').length(), 400); // .part 保留

    // 恢复：从 400 字节续传直到完成
    final done = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.completed);
    await dm.resume(savePath);
    await done.timeout(const Duration(seconds: 10));

    expect(server.ranges, ['none', 'bytes=400-']);
    expect(await File(savePath).readAsBytes(), bytes);
  });

  test('取消：删除 .part 并从任务列表移除', () async {
    final bytes = List<int>.generate(1000, (i) => i % 7);
    final savePath = '${tmpDir.path}/model.gguf';
    final server = FakeRangeServer(bytes, hangAfterBytes: 400);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final task = await dm.start(
        url: 'https://example.com/model.gguf',
        displayName: 'model',
        savePath: savePath);
    await waitUntil(() => task.receivedBytes >= 400);
    expect(await File('$savePath.part').exists(), true);

    await dm.cancel(savePath);
    await waitUntil(() => dm.taskOf(savePath) == null);

    expect(dm.taskOf(savePath), isNull);
    expect(await File('$savePath.part').exists(), false); // .part 已删除
    expect(await File(savePath).exists(), false);
  });

  test('并发互斥：downloading 中重复 start/resume 不产生第二个请求', () async {
    final bytes = List<int>.generate(1000, (i) => i % 7);
    final savePath = '${tmpDir.path}/model.gguf';
    const url = 'https://example.com/model.gguf';
    final server = FakeRangeServer(bytes, hangAfterBytes: 400);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final task = await dm.start(
        url: url, displayName: 'model', savePath: savePath);
    await waitUntil(() => task.receivedBytes >= 400);

    final again = await dm.start(
        url: url, displayName: 'model', savePath: savePath); // C1 直接返回
    expect(identical(again, task), true);
    await dm.resume(savePath); // C1 downloading 中忽略
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(server.requested.length, 1); // 无第二个并发请求
    expect(task.status, DownloadStatus.downloading);

    await dm.cancel(savePath);
  });

  test('init 恢复：downloading → paused 且保留进度', () async {
    final savePath = '${tmpDir.path}/model.gguf';
    await File('$savePath.part')
        .writeAsBytes(List<int>.filled(400, 1), flush: true);
    SharedPreferences.setMockInitialValues({
      'download_tasks': jsonEncode([
        {
          'id': savePath,
          'url': 'https://example.com/model.gguf',
          'displayName': 'model',
          'savePath': savePath,
          'totalBytes': 1000,
          'expectedSha256': null,
          'receivedBytes': 400,
          'status': 'downloading',
        },
      ]),
    });
    final dm =
        DownloadManager(dio: Dio()..httpClientAdapter = FakeRangeServer([]));
    await dm.init();

    final task = dm.taskOf(savePath);
    expect(task, isNotNull);
    expect(task!.status, DownloadStatus.paused); // 中断任务恢复为 paused
    expect(task.receivedBytes, 400);
    expect(dm.tasks.length, 1);
  });

  test('init 容错：单条损坏记录不影响其余任务恢复', () async {
    final savePath = '${tmpDir.path}/ok.gguf';
    await File('$savePath.part').writeAsBytes(List<int>.filled(10, 1));
    SharedPreferences.setMockInitialValues({
      'download_tasks': jsonEncode([
        {'id': 'bad'}, // 缺字段，fromJson 应抛错并被跳过
        {
          'id': savePath,
          'url': 'https://example.com/ok.gguf',
          'displayName': 'ok',
          'savePath': savePath,
          'totalBytes': 10,
          'expectedSha256': null,
          'receivedBytes': 10,
          'status': 'paused',
        },
      ]),
    });
    final dm =
        DownloadManager(dio: Dio()..httpClientAdapter = FakeRangeServer([]));
    await dm.init();

    expect(dm.tasks.length, 1);
    expect(dm.taskOf(savePath)!.status, DownloadStatus.paused);
  });

  test('串行队列：同一时刻仅 1 个任务，第二个排队自动启动', () async {
    const urlA = 'https://example.com/a.gguf';
    const urlB = 'https://example.com/b.gguf';
    final bytesA = List<int>.generate(300, (i) => i % 256);
    final bytesB = List<int>.generate(200, (i) => 255 - i % 256);
    final server = FakeRangeServer([], files: {urlA: bytesA, urlB: bytesB});
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final tA = await dm.start(
        url: urlA, displayName: 'a', savePath: '${tmpDir.path}/a.gguf');
    final tB = await dm.start(
        url: urlB, displayName: 'b', savePath: '${tmpDir.path}/b.gguf');

    expect(tA.status, DownloadStatus.downloading); // 第一个立即下载
    expect(tB.status, DownloadStatus.queued); // 第二个排队

    final doneB = dm.events.firstWhere(
        (t) => t.id == tB.id && t.status == DownloadStatus.completed);
    await doneB.timeout(const Duration(seconds: 10));

    // 请求严格串行：A 结束后 B 才开始
    expect(server.log, ['start:$urlA', 'end:$urlA', 'start:$urlB', 'end:$urlB']);
    expect(await File('${tmpDir.path}/a.gguf').readAsBytes(), bytesA);
    expect(await File('${tmpDir.path}/b.gguf').readAsBytes(), bytesB);
    expect(tB.status, DownloadStatus.completed);
  });
}
