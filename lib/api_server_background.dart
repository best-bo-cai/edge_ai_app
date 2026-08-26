// lib/api_server_background.dart
// 后台 Dart 入口（三期需求 §2.1 START_STICKY 自愈路径）：
// 进程被系统回收后 ApiKeepAliveService 重启（intent == null），此时进程内
// 没有 UI 引擎，HTTP 服务需要由后台 FlutterEngine 执行本入口恢复：
// - 只初始化 API 服务所需的最小依赖（模型列表 + 服务本身），不碰 UI
// - 用户打开 App 时 MainActivity 会销毁本后台引擎，HTTP 监听随 main()
//   里的 init() 重建（同一条「退出前开着则自动恢复」路径）
import 'package:flutter/widgets.dart';

import 'core/services/api_server/api_server_service.dart';
import 'core/services/model_service.dart';

@pragma('vm:entry-point') // 防止 release 构建把非 main 入口摇树优化掉
Future<void> apiServerMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  // /v1/models 与推理调度依赖模型列表；后台无 UI，不初始化会话/下载等服务
  await ModelService().init();
  await ApiServerService.instance.init();
}
