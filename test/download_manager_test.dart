// test/download_manager_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:edge_ai_app/core/services/download_manager.dart';

/// 支持 Range 的内存文件服务（模拟 HF CDN）
class FakeRangeServer implements HttpClientAdapter {
  FakeRangeServer(this.bytes, {this.failFirstTimes = 0});
  final List<int> bytes;
  int failFirstTimes;
  final List<String> ranges = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (failFirstTimes > 0) {
      failFirstTimes--;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    }
    final range = options.headers['Range'] as String?;
    ranges.add(range ?? 'none');
    var chunk = bytes;
    var status = 200;
    final headers = <String, List<String>>{};
    if (range != null) {
      final start = int.parse(range.replaceAll(RegExp(r'[^0-9]'), ''));
      chunk = bytes.sublist(start);
      status = 206;
      headers[HttpHeaders.contentRangeHeader] = [
        'bytes $start-${bytes.length - 1}/${bytes.length}'
      ];
    }
    headers[HttpHeaders.contentLengthHeader] = ['${chunk.length}'];
    return ResponseBody(Stream.value(Uint8List.fromList(chunk)), status,
        headers: headers);
  }

  @override
  void close({bool force = false}) {}
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
}
