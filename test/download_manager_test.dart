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

/// 轮询等待条件成立（带超时保护；超时视为失败而非静默通过）
Future<void> waitUntil(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), true,
      reason: 'waitUntil 超时（${timeout.inMilliseconds}ms）条件仍未成立');
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
    const url = 'https://example.com/model.gguf';
    final server = FakeRangeServer(bytes, hangAfterBytes: 400);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    // 先下载 400 字节后暂停，产生归属明确（有任务记录）的 .part
    final task = await dm.start(
        url: url, displayName: 'model', savePath: savePath);
    await waitUntil(() => task.receivedBytes >= 400);
    await dm.pause(savePath);
    await waitUntil(() => task.status == DownloadStatus.paused);

    // 再次 start 同一任务：从 400 字节续传直到完成
    final done = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.completed);
    await dm.start(url: url, displayName: 'model', savePath: savePath);
    await done.timeout(const Duration(seconds: 10));

    expect(server.ranges, ['none', 'bytes=400-']);
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

  test('P1 防重入：并发 start+resume 仅启动一个 _runLoop（请求数=1）', () async {
    final bytes = List<int>.generate(1000, (i) => i % 7);
    final savePath = '${tmpDir.path}/model.gguf';
    const url = 'https://example.com/model.gguf';
    // 经 init 恢复 paused 任务（.part 400 字节），此后尚无任何请求
    await File('$savePath.part').writeAsBytes(bytes.sublist(0, 400), flush: true);
    SharedPreferences.setMockInitialValues({
      'download_tasks': jsonEncode([
        {
          'id': savePath,
          'url': url,
          'displayName': 'model',
          'savePath': savePath,
          'totalBytes': 1000,
          'expectedSha256': null,
          'receivedBytes': 400,
          'status': 'paused',
        },
      ]),
    });
    final server = FakeRangeServer(bytes);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);
    await dm.init();

    // start() 挂起在 await exists() 时 resume() 抢跑置 downloading 并启动
    // _runLoop；start 恢复后不再复查状态、直接 unawaited(_run(task))，
    // 若无 _isRunning 防重入标志将双开 _runLoop 双写 .part
    final startFuture =
        dm.start(url: url, displayName: 'model', savePath: savePath);
    await dm.resume(savePath);
    await startFuture;

    final done = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.completed);
    await done.timeout(const Duration(seconds: 10));

    expect(server.requested.length, 1); // 双开则会发出第二个请求
    expect(server.ranges.single, 'bytes=400-');
    expect(await File(savePath).readAsBytes(), bytes);
  });

  test('P2: 孤儿 .part 不被新任务复用（防跨源续传损坏）', () async {
    final bytes = List<int>.generate(1000, (i) => i % 256);
    final savePath = '${tmpDir.path}/model.gguf';
    // 无任务记录：磁盘残留来源不明的 .part
    await File('$savePath.part').writeAsBytes(List<int>.filled(400, 9));
    final server = FakeRangeServer(bytes);
    final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

    final done = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.completed);
    await dm.start(
        url: 'https://example.com/model.gguf',
        displayName: 'model',
        savePath: savePath);
    await done.timeout(const Duration(seconds: 10));

    expect(server.ranges.single, 'none'); // 未携带 Range（未复用残留 .part）
    expect(await File(savePath).readAsBytes(), bytes); // 无残留字节混入
  });

  test('rename 前取消：任务不复活、不产生最终文件', () async {
    // 2MB 数据拉长 SHA256 校验窗口，确保取消发生在校验期间（rename 之前）
    final bytes = List<int>.generate(2 * 1024 * 1024, (i) => i % 251);
    final savePath = '${tmpDir.path}/model.gguf';
    final dm = DownloadManager(
        dio: Dio()..httpClientAdapter = FakeRangeServer(bytes));

    final verifying = dm.events.firstWhere(
        (t) => t.id == savePath && t.status == DownloadStatus.verifying);
    await dm.start(
      url: 'https://example.com/model.gguf',
      displayName: 'model',
      savePath: savePath,
      expectedSha256: sha256.convert(bytes).toString(),
    );
    await verifying.timeout(const Duration(seconds: 10));

    // 校验期间取消：任务被移除、.part 被删，校验完成后不得 rename 复活
    await dm.cancel(savePath);
    await waitUntil(() => dm.taskOf(savePath) == null);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(dm.taskOf(savePath), isNull);
    expect(await File(savePath).exists(), false); // 未 rename 出最终文件
    expect(await File('$savePath.part').exists(), false);
  });

  test('failed/paused 后队列自动继续下载下一个任务', () async {
    // —— 场景 1：前序 paused 释放串行队列 ——
    {
      const urlP = 'https://example.com/p.gguf';
      const urlQ = 'https://example.com/q.gguf';
      final bytesP = List<int>.generate(1000, (i) => i % 7);
      final bytesQ = List<int>.generate(200, (i) => i % 11);
      final server = FakeRangeServer([], files: {
        urlP: bytesP,
        urlQ: bytesQ,
      }, hangAfterBytes: 400);
      final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

      final tP = await dm.start(
          url: urlP, displayName: 'p', savePath: '${tmpDir.path}/p.gguf');
      // 订阅须早于 Q 启动：broadcast 流中已发出的事件无法补收
      final doneQ = dm.events.firstWhere((t) =>
          t.id == '${tmpDir.path}/q.gguf' &&
          t.status == DownloadStatus.completed);
      final tQ = await dm.start(
          url: urlQ, displayName: 'q', savePath: '${tmpDir.path}/q.gguf');
      expect(tQ.status, DownloadStatus.queued);

      await waitUntil(() => tP.receivedBytes >= 400);
      await dm.pause(tP.id);
      await waitUntil(() => tP.status == DownloadStatus.paused);

      await doneQ.timeout(const Duration(seconds: 10));

      expect(tQ.status, DownloadStatus.completed);
      expect(await File('${tmpDir.path}/q.gguf').readAsBytes(), bytesQ);
    }

    // —— 场景 2：前序 failed（SHA256 校验失败，无重试延迟）释放串行队列 ——
    {
      const urlF = 'https://example.com/f.gguf';
      const urlG = 'https://example.com/g.gguf';
      final bytesF = List<int>.generate(300, (i) => i % 13);
      final bytesG = List<int>.generate(200, (i) => i % 17);
      final server = FakeRangeServer([], files: {
        urlF: bytesF,
        urlG: bytesG,
      });
      final dm = DownloadManager(dio: Dio()..httpClientAdapter = server);

      // 订阅须早于 G 启动：broadcast 流中已发出的事件无法补收
      final doneG = dm.events.firstWhere((t) =>
          t.id == '${tmpDir.path}/g.gguf' &&
          t.status == DownloadStatus.completed);
      final tF = await dm.start(
          url: urlF,
          displayName: 'f',
          savePath: '${tmpDir.path}/f.gguf',
          expectedSha256: 'deadbeef'); // 必然校验失败
      final tG = await dm.start(
          url: urlG, displayName: 'g', savePath: '${tmpDir.path}/g.gguf');
      expect(tG.status, DownloadStatus.queued);

      await waitUntil(() => tF.status == DownloadStatus.failed);
      await doneG.timeout(const Duration(seconds: 10));

      expect(tG.status, DownloadStatus.completed); // failed 后队列自动继续
      expect(await File('${tmpDir.path}/f.gguf').exists(), false);
      expect(await File('${tmpDir.path}/g.gguf').readAsBytes(), bytesG);
    }
  });
}
