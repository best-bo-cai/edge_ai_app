import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/compatibility.dart';

/// 设备硬件检测（需求 2.1）：RAM / ABI / 核心数 / 可用存储
class DeviceCapabilityService {
  static const MethodChannel _channel = MethodChannel('edge_ai_app/device_info');

  /// 静默采集；平台不支持时自动降级（RAM 为 null → 引擎按 4GB 保守估算）
  Future<DeviceCapability> getCapability() async {
    String abi = 'unknown';
    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        abi = info.supportedAbis.isNotEmpty ? info.supportedAbis.first : 'unknown';
      } else if (Platform.isIOS) {
        abi = 'arm64';
      } else if (!kIsWeb) {
        abi = Platform.operatingSystem;
      }
    } catch (_) {}

    int? totalRam;
    int? freeDisk;
    try {
      final dir = await getApplicationDocumentsDirectory();
      totalRam = await _channel.invokeMethod<int>('getTotalRam');
      freeDisk = await _channel.invokeMethod<int>('getFreeDisk', {'path': dir.path});
    } catch (_) {
      // 平台通道未实现（桌面/单测）→ 保持 null，走保守降级
    }

    return DeviceCapability(
      totalRamBytes: totalRam,
      cpuCores: Platform.numberOfProcessors,
      abi: abi,
      freeDiskBytes: freeDisk,
    );
  }
}
