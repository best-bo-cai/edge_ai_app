// lib/features/settings/api_server_screen.dart
// API 服务开关页（二期 §5.5 + 三期 §2.3/§3.2/§4）：
// - 服务启停开关（持久化：退出前开着则下次启动自动恢复；开启时前台服务保活）
// - 端口配置（49152~65535，运行中锁定；存量端口越界自动迁移 + 一次性提示）
// - API Key 管理：展示/重新生成/自定义
// - 接入信息：多 IP 列表（WiFi 优先，蜂窝标注不可达）+ 复制；网络变化自动刷新
// - 保活引导卡片：电池优化检测/一键设置 + 厂商自启动文字指引（可不再提示）
// - 调用统计：总调用/失败数（明细见 api_call_logs）
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/api_server/api_server_service.dart';
import '../../core/services/keepalive/keepalive_service.dart';
import 'api_call_log_screen.dart';

class ApiServerScreen extends StatefulWidget {
  const ApiServerScreen({super.key});

  @override
  State<ApiServerScreen> createState() => _ApiServerScreenState();
}

class _ApiServerScreenState extends State<ApiServerScreen>
    with WidgetsBindingObserver {
  final ApiServerService _service = ApiServerService.instance;
  late final TextEditingController _portController;
  late final TextEditingController _keyController;

  // 引导卡片状态（三期 §4.1）
  static const String _prefHideGuide = 'api_server_hide_keepalive_guide';
  bool _hideGuide = false;
  bool _ignoringBattery = true;
  bool _notificationsEnabled = true;
  String _manufacturer = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 回前台时重查 IP 与引导状态
    _portController = TextEditingController(text: _service.port.toString());
    _keyController = TextEditingController(text: _service.apiKey);
    _service.addListener(_onChanged);
    _loadGuideState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_onChanged);
    _portController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 回前台：重查接入地址（网络可能已变化）与电池优化状态（用户可能刚从
      // 系统设置页返回）
      _service.refreshAddresses();
      _refreshKeepAliveState();
    }
  }

  Future<void> _loadGuideState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _hideGuide = prefs.getBool(_prefHideGuide) ?? false;
    });
    await _refreshKeepAliveState();
  }

  Future<void> _refreshKeepAliveState() async {
    final ignoring = await KeepAliveService.isIgnoringBatteryOptimizations();
    final notif = await KeepAliveService.areNotificationsEnabled();
    String manufacturer = '';
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        manufacturer = info.manufacturer;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _ignoringBattery = ignoring;
      _notificationsEnabled = notif;
      _manufacturer = manufacturer;
    });
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    // 端口显示同步服务当前值
    final portText = _service.port.toString();
    if (_portController.text != portText) {
      _portController.text = portText;
    }
  }

  Future<void> _toggleServer(bool enabled) async {
    if (enabled) {
      await _service.start();
      if (_service.status == ApiServerStatus.error && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_service.lastError ?? '启动失败'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else {
      await _service.stop();
    }
  }

  Future<void> _applyPort() async {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < ApiServerService.minPort || port > ApiServerService.maxPort) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                '端口需在 ${ApiServerService.minPort}~${ApiServerService.maxPort} 之间'),
          ),
        );
      }
      return;
    }
    await _service.setPort(port);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: port == _service.port ? const Text('端口已保存') : const Text('服务运行中，端口不可修改')),
      );
    }
  }

  Future<void> _regenerateKey() async {
    final key = 'edge-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
        '${_randomHex(16)}';
    _keyController.text = key;
    await _service.setApiKey(key);
  }

  static String _randomHex(int length) {
    const chars = '0123456789abcdef';
    final now = DateTime.now().microsecondsSinceEpoch;
    final sb = StringBuffer();
    for (var i = 0; i < length; i++) {
      sb.write(chars[(now >> (i % 16 * 2)) % 16]);
    }
    return sb.toString();
  }

  Future<void> _applyKey() async {
    await _service.setApiKey(_keyController.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API Key 已保存')),
      );
    }
  }

  Future<void> _requestBatteryOptimization() async {
    await KeepAliveService.requestIgnoreBatteryOptimizations();
    // 用户从系统设置页返回时 didChangeAppLifecycleState 会重查状态
  }

  Future<void> _hideGuideForever() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefHideGuide, true);
    if (mounted) {
      setState(() => _hideGuide = true);
    }
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制$label')),
    );
  }

  /// 厂商自启动设置路径（三期 §4.1：各厂商无标准入口，仅文字指引）
  String get _autostartHint {
    final m = _manufacturer.toLowerCase();
    if (m.contains('xiaomi') || m.contains('redmi')) {
      return '设置 → 应用设置 → 应用管理 → edge_ai_app → 自启动';
    }
    if (m.contains('huawei') || m.contains('honor')) {
      return '设置 → 应用 → 应用启动管理 → edge_ai_app → 允许自启动';
    }
    if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) {
      return '设置 → 应用管理 → edge_ai_app → 允许自启动';
    }
    if (m.contains('vivo') || m.contains('iqoo')) {
      return '设置 → 电池 → 后台高耗电 → edge_aiapp 允许后台运行';
    }
    return '在系统设置的电池/应用管理中允许 edge_aiapp 自启动与后台运行';
  }

  @override
  Widget build(BuildContext context) {
    final running = _service.isRunning;
    final theme = Theme.of(context);
    final addresses = _service.addresses;
    final guideVisible =
        running && !_hideGuide && (!_ignoringBattery || !_notificationsEnabled);

    return Scaffold(
      appBar: AppBar(title: const Text('API 服务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 存量端口迁移一次性提示（三期 §3.3）
          if (_service.portMigrated)
            Material(
              color: theme.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '端口策略已调整（${ApiServerService.minPort}~${ApiServerService.maxPort}），'
                        '原端口已自动迁移为 ${ApiServerService.defaultPort}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _service.clearPortMigrated,
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ),
            ),
          if (_service.portMigrated) const SizedBox(height: 12),

          // 服务总开关
          Card(
            child: SwitchListTile(
              title: const Text('对外提供大模型服务'),
              subtitle: Text(
                running
                    ? '监听 0.0.0.0:${_service.port}（局域网可访问）'
                    : '关闭中',
                style: TextStyle(
                  color: running ? Colors.green : theme.hintColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              secondary: Icon(
                running ? Icons.dns : Icons.dns_outlined,
                color: running ? Colors.green : theme.hintColor,
              ),
              value: running,
              onChanged: _service.apiKey.isEmpty ? null : _toggleServer,
            ),
          ),
          if (_service.apiKey.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '请先设置 API Key 后再开启服务',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (_service.status == ApiServerStatus.error &&
              _service.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _service.lastError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),

          const SizedBox(height: 16),

          // API Key
          const _SectionTitle('API Key'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '调用方需携带 Bearer token（OpenAI 风格）或 x-api-key 头（Anthropic 风格）',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _keyController,
                          decoration: const InputDecoration(
                            labelText: 'API Key',
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: '复制',
                        onPressed: _keyController.text.isEmpty
                            ? null
                            : () => _copy(_keyController.text, ' API Key'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('随机生成'),
                        onPressed: _regenerateKey,
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: _keyController.text.trim().isEmpty
                            ? null
                            : _applyKey,
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 端口
          const _SectionTitle('端口'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (running)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '服务运行中，停止后可修改端口',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          enabled: !running,
                          decoration: const InputDecoration(
                            labelText:
                                '监听端口（${ApiServerService.minPort}~${ApiServerService.maxPort}）',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: running ? null : _applyPort,
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 接入信息（三期 §3.2：多 IP 全列出，WiFi 优先）
          const _SectionTitle('接入信息（其他设备/应用填这些）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (addresses.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '未连接网络，仅限本机访问',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                    ),
                  for (final addr in addresses)
                    _addressRow(context, addr),
                  _addressRow(
                    context,
                    AccessAddress('127.0.0.1', '本机'),
                  ),
                  const Divider(),
                  Text(
                    '局域网内任何设备都可尝试连接，API Key 是唯一防线；'
                    '模型名从模型列表接口获取，请求未安装的模型将返回 404。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 调用统计（整卡可点进入日志明细；数字从日志表聚合，与日志页一致）
          const _SectionTitle('调用统计'),
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const ApiCallLogScreen(),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: _StatCell(
                        label: '总调用',
                        value: _service.totalCalls.toString(),
                      ),
                    ),
                    Expanded(
                      child: _StatCell(
                        label: '失败',
                        value: _service.failedCalls.toString(),
                        valueColor: _service.failedCalls > 0
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: theme.hintColor),
                  ],
                ),
              ),
            ),
          ),

          // 保活引导卡片（三期 §4.1：非必须，可永久关闭）
          if (guideVisible) ...[
            const SizedBox(height: 16),
            const _SectionTitle('保活建议（非必须）'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _ignoringBattery ? Icons.check_circle : Icons.battery_alert,
                          size: 18,
                          color: _ignoringBattery ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _ignoringBattery ? '已忽略电池优化' : '建议忽略电池优化',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        if (!_ignoringBattery)
                          TextButton(
                            onPressed: _requestBatteryOptimization,
                            child: const Text('一键设置'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _autostartHint,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                    ),
                    if (!_notificationsEnabled) ...[
                      const SizedBox(height: 8),
                      Text(
                        '通知权限已禁用：保活不受影响，仅无运行状态通知',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _hideGuideForever,
                        child: const Text('不再提示'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _addressRow(BuildContext context, AccessAddress addr) {
    final theme = Theme.of(context);
    final url = 'http://${addr.ip}:${_service.port}/v1';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              addr.lanReachable ? addr.label : '${addr.label}(不可达)',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
          Expanded(
            child: SelectableText(
              url,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: addr.lanReachable ? null : theme.hintColor,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制',
            onPressed: () => _copy(url, '接入地址'),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatCell({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          value,
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600, color: valueColor),
        ),
        const SizedBox(height: 4),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      ],
    );
  }
}
