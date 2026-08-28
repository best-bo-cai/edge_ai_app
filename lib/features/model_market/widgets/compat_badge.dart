// lib/features/model_market/widgets/compat_badge.dart
import 'package:flutter/material.dart';

import '../../../core/models/compatibility.dart';

/// 兼容性标签（需求 2.3：完美适配/可运行/超出设备配置）
class CompatBadge extends StatelessWidget {
  const CompatBadge({super.key, required this.level});

  final CompatibilityLevel level;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (level) {
      CompatibilityLevel.perfect => ('完美适配', Colors.green),
      CompatibilityLevel.runnable => ('可运行', Colors.orange),
      CompatibilityLevel.overkill => ('超出设备配置', Colors.red),
      CompatibilityLevel.unknown => ('未知', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
