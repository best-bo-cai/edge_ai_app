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

    test('TQ/MXFP4 新量化格式分支', () {
      expect(QuantParser.parseFileName('gpt-oss-20b-tq1_0.gguf')!.label, 'TQ1_0');
      expect(QuantParser.parseFileName('gpt-oss-120b-tq2_0.gguf')!.label, 'TQ2_0');
      expect(QuantParser.parseFileName('gpt-oss-20b-mxfp4.gguf')!.label, 'MXFP4');
      expect(QuantParser.parseFileName('GPT-OSS-20B-MXFP4.gguf')!.label, 'MXFP4');
    });

    test('左边界断言：量化标识须为独立 token', () {
      // 字母/数字紧邻的量化串不误匹配（"tq1_0" 不解析出 "Q1_0"）
      expect(QuantParser.parseFileName('GPTQ4.gguf'), isNull);
      expect(QuantParser.parseFileName('modelGQ4_K_M.gguf'), isNull);
      expect(QuantParser.parseFileName('modelgq4_k_m.gguf'), isNull);
      expect(QuantParser.parseFileName('v2Q4_K_M.gguf'), isNull);
      expect(QuantParser.parseFileName('embf16model.gguf'), isNull);
      // 合法边界：字符串开头、下划线
      expect(QuantParser.parseFileName('Q4_K_M.gguf')!.label, 'Q4_K_M');
      expect(QuantParser.parseFileName('model_Q4_K_M.gguf')!.label, 'Q4_K_M');
    });

    test('位宽约束：非法位宽返回 null', () {
      expect(QuantParser.parseFileName('model-Q40_K_M.gguf'), isNull); // 多位数字
      expect(QuantParser.parseFileName('model-Q9_0.gguf'), isNull); // 9bit 不存在
      expect(QuantParser.parseFileName('model-Q1_K.gguf'), isNull); // Q1 不存在（仅 IQ1/TQ1）
      expect(QuantParser.parseFileName('model-IQ40_XS.gguf'), isNull); // 多位数字
      expect(QuantParser.parseFileName('model-IQ9.gguf'), isNull);
    });

    test('位宽边界值（Q2/Q8、IQ1/IQ4）可匹配', () {
      expect(QuantParser.parseFileName('model-Q2_K.gguf')!.label, 'Q2_K');
      expect(QuantParser.parseFileName('model-Q8_0.gguf')!.label, 'Q8_0');
      expect(QuantParser.parseFileName('model-IQ1_M.gguf')!.label, 'IQ1_M');
      expect(QuantParser.parseFileName('model-IQ4_NL.gguf')!.label, 'IQ4_NL');
    });

    test('后缀段数上限：最多 2 段', () {
      expect(QuantParser.parseFileName('model-Q4_K_M_X.gguf')!.label, 'Q4_K_M');
      expect(QuantParser.parseFileName('model-Q4_K_M_X_Y.gguf')!.label, 'Q4_K_M');
    });

    test('新格式质量评级', () {
      expect(QuantParser.parseFileName('gpt-oss-20b-mxfp4.gguf')!.quality, contains('平衡'));
      expect(QuantParser.parseFileName('model-tq1_0.gguf')!.quality, contains('极致压缩'));
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

    test('quant 解析结果缓存（同一实例复用同一对象）', () {
      final file = HfModelFile.fromJson('a/b', {'path': 'x-q4_k_m.gguf', 'size': 1});
      expect(file.quant, same(file.quant));
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
