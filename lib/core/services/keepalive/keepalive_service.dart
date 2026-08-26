// lib/core/services/keepalive/keepalive_service.dart
// 前台服务保活 + 系统引导（三期需求 §2/§4）：
// - MethodChannel 桥接 Android ApiKeepAliveService（specialUse 前台服务）
// - 电池优化检测/一键申请（标准系统 Intent，非必须）
// - 通知权限检测（Android 13+；拒绝时服务照常运行，仅无可见通知）
// - 非 Android 平台全部 no-op，服务开启不受影响
import 'dart:io';

import 'package:flutter/services.dart';

class KeepAliveService {
  static const MethodChannel _channel =
      MethodChannel('edge_ai_app/keepalive');

  static bool get _supported => Platform.isAndroid;

  /// 启动前台服务（通知展示局域网接入地址）。失败不阻断 HTTP 服务，
  /// 仅失去保活能力（返回 false 由 UI 提示）。
  static Future<bool> startService({
    required int port,
    required String address,
  }) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('startService', {
            'port': port,
            'address': address,
          }) ??
          false;
    } catch (e) {
      // ignore: avoid_print
      print('KeepAlive startService failed: $e');
      return false;
    }
  }

  static Future<void> stopService() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('stopService');
    } catch (_) {
      // 停止失败无需处理（进程退出时服务随之销毁）
    }
  }

  /// 是否已忽略电池优化（引导卡片勾选态）
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_supported) return true;
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true; // 查询失败不展示引导，避免误报
    } catch (_) {
      return true;
    }
  }

  /// 通知权限是否开启（Android 13+ 运行时权限）
  static Future<bool> areNotificationsEnabled() async {
    if (!_supported) return true;
    try {
      return await _channel.invokeMethod<bool>('areNotificationsEnabled') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// 申请忽略电池优化（系统设置页；部分 ROM 回退到电池优化列表页）
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!_supported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }
}
