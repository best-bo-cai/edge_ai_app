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

  /// 模型实际可用的运行内存预算：物理内存 × [CompatibilityEngine.usableRamRatio]。
  /// 系统进程、GPU/固件保留、其他应用与本 App 自身均需占用内存，
  /// 移动端留给大模型的内存通常不足物理内存的一半。
  int get usableRamBytes =>
      (assumedRamBytes * CompatibilityEngine.usableRamRatio).round();
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

  /// 模型可用内存占物理内存的比例：系统进程、其他应用与本 App 自身
  /// 开销约占一半，兼容性判定按该预算保守评估
  /// （用户实测反馈：16GB 机型实际可提供给模型的内存仅约一半甚至更低）
  static const double usableRamRatio = 0.5;

  /// 参数量合理性上限（十亿）：当前最大开源模型（DeepSeek-V3 约 671B）
  /// 也远小于 2000B，超出视为误匹配（如版本号、容量标识）
  static const double _maxPlausibleParamBillions = 2000;

  /// 运行内存开销系数：GGUF 加载除权重外还需 KV Cache、计算缓冲等，
  /// 经验上总需求约为文件大小的 1.2 倍
  static const double _ramOverheadFactor = 1.2;

  /// perfect 档占可用内存预算上限：需求内存 ≤ 预算 60%，
  /// 为系统及其他应用预留约 40% 余量
  static const double _perfectRamRatio = 0.6;

  /// runnable 档占可用内存预算上限：占用 60%~85% 时可运行但偏紧，
  /// 超过 85% 有被系统 OOM 回收风险
  static const double _runnableRamRatio = 0.85;

  /// 从名称提取参数量（十亿）。如 "Qwen2.5-0.5B" → 0.5
  static double? extractParamBillions(String name) {
    for (final match in _paramRegex.allMatches(name)) {
      final value = double.tryParse(match.group(1)!);
      if (value != null && value > 0 && value < _maxPlausibleParamBillions) {
        return value;
      }
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
  ///
  /// 边界归属：档位下界计入上一档（含边界值），如恰好 4GB 属 4-6GB 档（上限 1.5B）
  static double maxParamsForRam(int totalRamBytes) {
    final gb = totalRamBytes / (1024 * 1024 * 1024);
    if (gb < 4) return 1.0;
    if (gb < 6) return 1.5;
    if (gb < 8) return 3.0;
    if (gb < 12) return 7.0;
    return 13.0;
  }

  /// 列表级粗筛（基于仓库名）。以"模型可用内存"（物理内存的一半）
  /// 代入需求分档表；超出设备配置的模型在广场列表中直接过滤不展示
  static CompatibilityLevel evaluateModel(DeviceCapability device, HfModel model) {
    final params = extractParamBillions(model.name) ?? _keywordGuess(model.name);
    if (params == null) return CompatibilityLevel.unknown;
    final tier = maxParamsForRam(device.usableRamBytes);
    if (params <= tier) return CompatibilityLevel.perfect;
    if (params <= tier * 1.5) return CompatibilityLevel.runnable;
    return CompatibilityLevel.overkill;
  }

  /// 文件级精确判断：运行内存需求 ≈ 文件大小 × 开销系数，
  /// 与"模型可用内存"（物理内存的一半）比较
  static CompatibilityLevel evaluateFile(DeviceCapability device, HfModelFile file) {
    // 脏数据防御：size 缺失/非法（≤0）时无法估算，不做判断
    if (file.sizeBytes <= 0) return CompatibilityLevel.unknown;
    final usable = device.usableRamBytes;
    final need = (file.sizeBytes * _ramOverheadFactor).round();
    if (need <= usable * _perfectRamRatio) return CompatibilityLevel.perfect;
    if (need <= usable * _runnableRamRatio) return CompatibilityLevel.runnable;
    return CompatibilityLevel.overkill;
  }
}
