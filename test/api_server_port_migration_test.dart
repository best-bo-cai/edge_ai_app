// test/api_server_port_migration_test.dart
// 三期端口策略（需求 §3.3）：
// - 默认端口 52415，合法范围 49152~65535
// - 存量越界端口（如二期默认的 8080）升级时自动迁移 + 一次性提示
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:edge_ai_app/core/services/api_server/api_server_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('端口策略与存量迁移', () {
    test('无已保存端口 → 使用默认端口且无迁移提示', () async {
      SharedPreferences.setMockInitialValues({});
      await ApiServerService.instance.init();
      expect(ApiServerService.instance.port, ApiServerService.defaultPort);
      expect(ApiServerService.instance.portMigrated, false);
    });

    test('存量 8080 越界 → 自动迁移为默认端口并置提示标记', () async {
      SharedPreferences.setMockInitialValues({'api_server_port': 8080});
      await ApiServerService.instance.init();
      expect(ApiServerService.instance.port, ApiServerService.defaultPort);
      expect(ApiServerService.instance.portMigrated, true);
      // 迁移结果已持久化（下次启动不再触发）
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('api_server_port'), ApiServerService.defaultPort);
      // UI 消费后清除
      ApiServerService.instance.clearPortMigrated();
      expect(ApiServerService.instance.portMigrated, false);
    });

    test('范围内的已保存端口（60000）→ 原样保留', () async {
      SharedPreferences.setMockInitialValues({'api_server_port': 60000});
      await ApiServerService.instance.init();
      expect(ApiServerService.instance.port, 60000);
      expect(ApiServerService.instance.portMigrated, false);
    });

    test('默认端口与范围常量符合策略', () {
      expect(ApiServerService.minPort, 49152);
      expect(ApiServerService.maxPort, 65535);
      expect(ApiServerService.defaultPort, 52415);
      expect(
        ApiServerService.defaultPort >= ApiServerService.minPort &&
            ApiServerService.defaultPort <= ApiServerService.maxPort,
        isTrue,
      );
    });
  });
}
