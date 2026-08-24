// test/quant_parser_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_app/core/models/hf_catalog_models.dart';

void main() {
  group('QuantParser.parseFileName', () {
    test('解析常见量化后缀', () {
      expect(QuantParser.parseFileName('Qwen2.5-0.5B-Instruct-Q4_K_M.gguf')!.label, 'Q4_K_M');
      expect(QuantParser.parseFileName('Llama-3.2-1B-Instruct-Q8_0.gguf')!.label, 'Q8_0');
      expect(QuantParser.parseFileName('deepseek-r1-distill-qwen-1.5b-iq4_xs.gguf')!.label, 'IQ4_XS');
      expect(QuantParser.parseFileName('gemma-3-1b-it-bf16.gguf')!.label, 'BF16');
      expect(QuantParser.parseFileName('tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf')!.label, 'Q4_K_M');
      expect(QuantParser.parseFileName('model-q3_k_l.gguf')!.label, 'Q3_K_L');
    });

    test('无量化标识返回 null', () {
      expect(QuantParser.parseFileName('Qwen3-30B-A3B-Instruct.gguf'), isNull);
      expect(QuantParser.parseFileName('model.gguf'), isNull);
    });

    test('质量评级文案', () {
      expect(QuantParser.parseFileName('a-Q8_0.gguf')!.quality, contains('极高精度'));
      expect(QuantParser.parseFileName('a-Q4_K_M.gguf')!.quality, contains('平衡'));
      expect(QuantParser.parseFileName('a-bf16.gguf')!.quality, contains('未量化'));
    });
  });

  group('HfModelFile.fromJson', () {
    test('提取 path/size/lfs.oid', () {
      final file = HfModelFile.fromJson('Qwen/Qwen2.5-0.5B-Instruct-GGUF', {
        'type': 'file',
        'path': 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
        'size': 491400032,
        'lfs': {'oid': '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db', 'size': 491400032},
      });
      expect(file.sizeBytes, 491400032);
      expect(file.sha256, '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db');
      expect(file.fileName, 'qwen2.5-0.5b-instruct-q4_k_m.gguf');
      expect(file.quant!.label, 'Q4_K_M');
    });

    test('无 lfs 字段时 size 取顶层', () {
      final file = HfModelFile.fromJson('a/b', {'path': 'x.gguf', 'size': 123});
      expect(file.sizeBytes, 123);
      expect(file.sha256, isNull);
    });
  });

  group('HfModel.fromJson', () {
    test('解析列表接口字段', () {
      final m = HfModel.fromJson({
        'id': 'unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF',
        'downloads': 12748404,
        'likes': 918,
        'tags': ['gguf', 'qwen3'],
      });
      expect(m.author, 'unsloth');
      expect(m.name, 'Qwen3-Coder-30B-A3B-Instruct-GGUF');
      expect(m.downloads, 12748404);
      expect(m.tags, contains('gguf'));
      expect(m.files, isNull);
    });

    test('解析兜底清单（含内嵌 files）', () {
      final m = HfModel.fromJson({
        'id': 'Qwen/Qwen2.5-0.5B-Instruct-GGUF',
        'files': [
          {'path': 'qwen2.5-0.5b-instruct-q4_k_m.gguf', 'size': 491400032}
        ],
      });
      expect(m.files!.single.sizeBytes, 491400032);
    });
  });
}
