// lib/core/models/hf_catalog_models.dart

/// GGUF 量化级别
class QuantLevel {
  final String label;   // 原始标识，如 "Q4_K_M"
  final String quality; // 质量评级文案
  const QuantLevel(this.label, this.quality);
}

/// GGUF 文件名量化解析器
class QuantParser {
  /// 收紧规则（代码审查修复）：
  /// - 左/右边界断言：量化标识须为独立 token，"GPTQ4"→null、"tq1_0"→TQ1_0（而非 Q1_0）
  /// - 位宽约束：Q 限 2-8、IQ 限 1-4、TQ 限 1-2，"Q40"/"IQ9" 等多位/越界位宽不匹配
  /// - TQ1_0/TQ2_0 与 MXFP4 新格式分支
  /// - 后缀段数上限：最多 2 段（如 Q4_K_M），每段 1-3 个字母数字
  static final RegExp _pattern = RegExp(
    r'(?<![A-Za-z0-9])(?:(?:IQ[1-4]|Q[2-8])(?:_[A-Z0-9]{1,3}){0,2}|TQ[12]_0|MXFP4|BF16|F16|F32)(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  static QuantLevel? parseFileName(String fileName) {
    final match = _pattern.firstMatch(fileName);
    if (match == null) return null;
    final label = match.group(0)!.toUpperCase();
    return QuantLevel(label, qualityOf(label));
  }

  static String qualityOf(String label) {
    if (label == 'F32' || label == 'F16' || label == 'BF16') return '未量化（体积大）';
    if (label.startsWith('MXFP4')) return '平衡（推荐）'; // 4bit 微缩放（gpt-oss 官方格式）
    if (label.startsWith('Q8')) return '极高精度（几乎无损）';
    if (label.startsWith('Q6')) return '高精度';
    if (label.startsWith('Q5')) return '高质量';
    if (label == 'Q4_K_M' || label == 'IQ4_XS') return '平衡（推荐）';
    if (label.startsWith('Q4')) return '体积优先';
    if (label.startsWith('Q3')) return '低配设备';
    return '极致压缩（质量损失明显）';
  }
}

/// Hugging Face 模型仓库
class HfModel {
  final String id;                 // "Qwen/Qwen2.5-0.5B-Instruct-GGUF"
  final int downloads;
  final int likes;
  final List<String> tags;
  final List<HfModelFile>? files;  // 兜底清单内置；API 列表为 null

  const HfModel({
    required this.id,
    this.downloads = 0,
    this.likes = 0,
    this.tags = const [],
    this.files,
  });

  String get author => id.contains('/') ? id.split('/').first : '';
  String get name => id.contains('/') ? id.split('/').last : id;

  factory HfModel.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    return HfModel(
      id: id,
      downloads: (json['downloads'] as num?)?.toInt() ?? 0,
      likes: (json['likes'] as num?)?.toInt() ?? 0,
      tags:
          (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      files: (json['files'] as List?)
          ?.map((e) => HfModelFile.fromJson(id, e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 仓库中的单个 GGUF 文件
class HfModelFile {
  final String repoId;
  final String path;      // "qwen2.5-0.5b-instruct-q4_k_m.gguf"
  final int sizeBytes;
  final String? sha256;   // HF LFS oid

  HfModelFile({
    required this.repoId,
    required this.path,
    required this.sizeBytes,
    this.sha256,
  });

  String get fileName => path.split('/').last;

  /// 量化解析结果惰性计算并缓存（实例不可变，避免每次访问重复执行正则）
  late final QuantLevel? quant = QuantParser.parseFileName(fileName);

  factory HfModelFile.fromJson(String repoId, Map<String, dynamic> json) {
    final lfs = json['lfs'] as Map<String, dynamic>?;
    return HfModelFile(
      repoId: repoId,
      path: json['path'] as String,
      sizeBytes: ((lfs?['size'] ?? json['size'] ?? 0) as num).toInt(),
      sha256: lfs?['oid'] as String?,
    );
  }
}
