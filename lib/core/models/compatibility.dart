// lib/core/models/compatibility.dart
import 'hf_catalog_models.dart';

/// 兼容性等级（需求 2.3）
enum CompatibilityLevel { perfect, runnable, overkill, unknown }

extension CompatibilityLevelX on CompatibilityLevel {
  String get label => switch (this) {
        CompatibilityLevel.perfect => '完美适配',
        CompatibilityLevel.runnable => '可运行',
        CompatibilityLevel.overkill => '超出设备配置',
        CompatibilityLevel.unknown => '未知',
      };
}

/// 设备硬件能力（需求 2.1 采集结果）
class DeviceCapability {
  final int? totalRamBytes;  // null = 读取失败，按 4GB 保守估算
  final int cpuCores;
  final String abi;          // arm64-v8a / arm64 ...
  final int? freeDiskBytes;  // null = 未知（下载预检不拦截）

  const DeviceCapability({
    this.totalRamBytes,
    required this.cpuCores,
    required this.abi,
    this.freeDiskBytes,
  });

  int get assumedRamBytes => totalRamBytes ?? 4 * 1024 * 1024 * 1024;
  bool get isEstimated => totalRamBytes == null;
}

/// 存储空间预检（需求 2.4：剩余空间 ≥ 文件大小 + 2GB 运行缓存）
class StorageCheck {
  static const int runtimeCacheBytes = 2 * 1024 * 1024 * 1024;

  static bool hasEnoughSpace({required int? freeDiskBytes, required int fileSizeBytes}) {
    if (freeDiskBytes == null) return true;
    return freeDiskBytes >= fileSizeBytes + runtimeCacheBytes;
  }
}

/// 智能筛选引擎（需求 2.3）
class CompatibilityEngine {
  static final RegExp _paramRegex = RegExp(r'(\d+(?:\.\d+)?)\s*[bB](?![a-zA-Z0-9])');

  /// 从名称提取参数量（十亿）。如 "Qwen2.5-0.5B" → 0.5
  static double? extractParamBillions(String name) {
    for (final match in _paramRegex.allMatches(name)) {
      final value = double.tryParse(match.group(1)!);
      if (value != null && value > 0 && value < 2000) return value;
    }
    return null;
  }

  /// 需求关键词兜底（无参数量标识时的粗筛）
  static double? _keywordGuess(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('tiny')) return 0.7;
    if (lower.contains('mini')) return 1.5;
    if (lower.contains('small')) return 3.0;
    return null;
  }

  /// RAM 分档（按总内存，需求 2.3 表格）
  static double maxParamsForRam(int totalRamBytes) {
    final gb = totalRamBytes / (1024 * 1024 * 1024);
    if (gb < 4) return 1.0;
    if (gb < 6) return 1.5;
    if (gb < 8) return 3.0;
    if (gb < 12) return 7.0;
    return 13.0;
  }

  /// 列表级粗筛（基于仓库名）
  static CompatibilityLevel evaluateModel(DeviceCapability device, HfModel model) {
    final params = extractParamBillions(model.name) ?? _keywordGuess(model.name);
    if (params == null) return CompatibilityLevel.unknown;
    final tier = maxParamsForRam(device.assumedRamBytes);
    if (params <= tier) return CompatibilityLevel.perfect;
    if (params <= tier * 1.5) return CompatibilityLevel.runnable;
    return CompatibilityLevel.overkill;
  }

  /// 文件级精确判断：运行内存需求 ≈ 文件大小 × 1.2
  static CompatibilityLevel evaluateFile(DeviceCapability device, HfModelFile file) {
    final ram = device.assumedRamBytes;
    final need = (file.sizeBytes * 1.2).round();
    if (need <= ram * 0.6) return CompatibilityLevel.perfect;
    if (need <= ram * 0.85) return CompatibilityLevel.runnable;
    return CompatibilityLevel.overkill;
  }
}
