import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_app/core/services/model_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // flutter test 的 rootBundle 不含真实 assets；
    // mock 'flutter/assets' 通道直接从磁盘读取（测试 cwd = 项目根）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (ByteData? message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      final file = File(key);
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        return ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
      }
      return null;
    });
  });

  test('真实 asset 可加载且结构合法', () async {
    final models = await ModelService().loadFallbackModels();
    expect(models.length, greaterThanOrEqualTo(15));
    for (final m in models) {
      expect(m.id, contains('/'));
      expect(m.files, isNotNull);
      expect(m.files!.single.path.endsWith('.gguf'), isTrue,
          reason: '${m.id} 文件名必须以 .gguf 结尾');
    }
  });

  test('parseFallbackJson 解析内嵌文件与 sha256', () {
    const raw = '''
    { "models": [
      { "id": "a/b-GGUF",
        "files": [ { "path": "b-q4_k_m.gguf", "size": 100, "sha256": "abc" } ] }
    ] }
    ''';
    final models = ModelService.parseFallbackJson(raw);
    expect(models.single.id, 'a/b-GGUF');
    expect(models.single.files!.single.sha256, 'abc');
    expect(models.single.files!.single.quant!.label, 'Q4_K_M');
  });

  test('损坏 JSON 返回空列表（不抛异常）', () {
    expect(ModelService.parseFallbackJson('not json'), isEmpty);
  });
}
