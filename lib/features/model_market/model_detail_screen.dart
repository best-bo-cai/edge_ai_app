// lib/features/model_market/model_detail_screen.dart
// 最小占位实现：仅保证模型广场页编译通过，Task 8 将完整替换为
// 含量化文件列表、存储预检、蜂窝提醒与加载运行的详情页。
import 'package:flutter/material.dart';

import '../../core/models/hf_catalog_models.dart';

/// 模型详情页（占位）
class ModelDetailScreen extends StatelessWidget {
  const ModelDetailScreen({super.key, required this.model});

  final HfModel model;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(model.name)),
    );
  }
}
