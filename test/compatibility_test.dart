// test/compatibility_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_app/core/models/compatibility.dart';
import 'package:edge_ai_app/core/models/hf_catalog_models.dart';

const gb = 1024 * 1024 * 1024;

DeviceCapability cap(int ramGb, {int? freeDiskGb}) => DeviceCapability(
      totalRamBytes: ramGb * gb,
      cpuCores: 8,
      abi: 'arm64-v8a',
      freeDiskBytes: freeDiskGb == null ? null : freeDiskGb * gb,
    );

void main() {
  group('extractParamBillions', () {
    test('带小数参数量', () {
      expect(CompatibilityEngine.extractParamBillions('Qwen2.5-0.5B-Instruct-GGUF'), 0.5);
      expect(CompatibilityEngine.extractParamBillions('TinyLlama-1.1B-Chat'), 1.1);
      expect(CompatibilityEngine.extractParamBillions('Llama-3.2-1B-Instruct'), 1.0);
    });
    test('数字后不能紧跟字母（避免误匹配）', () {
      // "Qwen2.5" 中 2.5 后是 '-' 不是 B，不应返回 2.5
      expect(CompatibilityEngine.extractParamBillions('Gemma-2-2b-it-GGUF'), 2.0);
      expect(CompatibilityEngine.extractParamBillions('Qwen3-30B-A3B'), 30.0);
    });
    test('无参数量返回 null', () {
      expect(CompatibilityEngine.extractParamBillions('Phi-3.5-mini-instruct'), isNull);
    });
  });

  group('RAM 分档（需求表格）', () {
    test('各档位上限', () {
      expect(CompatibilityEngine.maxParamsForRam(3 * gb), 1.0);   // <4GB
      expect(CompatibilityEngine.maxParamsForRam(4 * gb), 1.5);   // 4-6GB
      expect(CompatibilityEngine.maxParamsForRam(6 * gb), 3.0);   // 6-8GB
      expect(CompatibilityEngine.maxParamsForRam(8 * gb), 7.0);   // 8-12GB
      expect(CompatibilityEngine.maxParamsForRam(12 * gb), 13.0); // >12GB
    });
  });

  group('evaluateModel 列表级粗筛', () {
    test('4GB 设备：0.5B 完美适配', () {
      const m = HfModel(id: 'a/Qwen2.5-0.5B-Instruct-GGUF');
      expect(CompatibilityEngine.evaluateModel(cap(4), m), CompatibilityLevel.perfect);
    });
    // 4GB 属 4-6GB 档（上限 1.5B）：1.5B 恰好达档 → perfect；
    // 2B 落在 (1.5, 1.5×1.5] → runnable；3B 超出 → overkill
    test('4GB 设备：1.5B 完美、2B 可运行、3B 超出', () {
      expect(CompatibilityEngine.evaluateModel(cap(4), const HfModel(id: 'a/Qwen2.5-1.5B-Instruct-GGUF')),
          CompatibilityLevel.perfect);
      expect(CompatibilityEngine.evaluateModel(cap(4), const HfModel(id: 'a/gemma-2-2b-it-GGUF')),
          CompatibilityLevel.runnable);
      expect(CompatibilityEngine.evaluateModel(cap(4), const HfModel(id: 'a/Qwen2.5-3B-Instruct-GGUF')),
          CompatibilityLevel.overkill);
    });
    test('8GB 设备：7B 完美适配', () {
      expect(CompatibilityEngine.evaluateModel(cap(8), const HfModel(id: 'a/Mistral-7B-Instruct-v0.3-GGUF')),
          CompatibilityLevel.perfect);
    });
    test('关键词兜底：TinyLlama 视为 0.7B', () {
      expect(CompatibilityEngine.evaluateModel(cap(4), const HfModel(id: 'a/TinyLlama-1.1B-Chat-v1.0-GGUF')),
          CompatibilityLevel.perfect);
      const noParam = HfModel(id: 'a/tinyllama-chat');
      expect(CompatibilityEngine.evaluateModel(cap(4), noParam), CompatibilityLevel.perfect);
    });
    test('无法判断 → unknown', () {
      expect(CompatibilityEngine.evaluateModel(cap(8), const HfModel(id: 'a/some-model-gguf')),
          CompatibilityLevel.unknown);
    });
    test('RAM 未知按 4GB 保守分档', () {
      const unknown = DeviceCapability(totalRamBytes: null, cpuCores: 8, abi: 'x');
      expect(CompatibilityEngine.evaluateModel(unknown, const HfModel(id: 'a/Qwen2.5-7B-GGUF')),
          CompatibilityLevel.overkill);
    });
  });

  group('evaluateFile 文件级精确判断', () {
    test('8GB 设备 + 2GB 文件 → 完美适配', () {
      final f = HfModelFile(repoId: 'a/b', path: 'x-q4_k_m.gguf', sizeBytes: 2 * gb);
      expect(CompatibilityEngine.evaluateFile(cap(8), f), CompatibilityLevel.perfect);
    });
    test('8GB 设备 + 4.5GB 文件 → 可运行', () {
      final f = HfModelFile(repoId: 'a/b', path: 'x-q4_k_m.gguf', sizeBytes: (4.5 * gb).round());
      expect(CompatibilityEngine.evaluateFile(cap(8), f), CompatibilityLevel.runnable);
    });
    test('4GB 设备 + 4GB 文件 → 超出', () {
      final f = HfModelFile(repoId: 'a/b', path: 'x-q4_k_m.gguf', sizeBytes: 4 * gb);
      expect(CompatibilityEngine.evaluateFile(cap(4), f), CompatibilityLevel.overkill);
    });
  });

  group('StorageCheck（需求 2.4：剩余 ≥ 文件+2GB）', () {
    test('空间充足', () {
      expect(StorageCheck.hasEnoughSpace(freeDiskBytes: 5 * gb, fileSizeBytes: 3 * gb), true);
    });
    test('空间不足', () {
      expect(StorageCheck.hasEnoughSpace(freeDiskBytes: 4 * gb, fileSizeBytes: 3 * gb), false);
    });
    test('未知空间不拦截', () {
      expect(StorageCheck.hasEnoughSpace(freeDiskBytes: null, fileSizeBytes: 3 * gb), true);
    });
  });
}
