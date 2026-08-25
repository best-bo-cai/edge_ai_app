// lib/features/settings/api_server_screen.dart
// API 服务开关页（二期需求 §5.5）：
// - 服务启停开关（持久化：退出前开着则下次启动自动恢复）
// - 端口配置（运行中锁定，需停止后修改）
// - API Key 管理：展示/重新生成/自定义
// - 接入信息：base_url + 两协议端点示例（供其他 App 配置）
// - 调用统计：总调用/失败数（明细见 api_call_logs）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/api_server/api_server_service.dart';

class ApiServerScreen extends StatefulWidget {
  const ApiServerScreen({super.key});

  @override
  State<ApiServerScreen> createState() => _ApiServerScreenState();
}

class _ApiServerScreenState extends State<ApiServerScreen> {
  final ApiServerService _service = ApiServerService.instance;
  late final TextEditingController _portController;
  late final TextEditingController _keyController;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(text: _service.port.toString());
    _keyController = TextEditingController(text: _service.apiKey);
    _service.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    _portController.dispose();
    _keyController.dispose();
    super.dispose();
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
    if (port == null || port < 1024 || port > 65535) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('端口需在 1024~65535 之间')),
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

  @override
  Widget build(BuildContext context) {
    final running = _service.isRunning;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('API 服务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 服务总开关
          Card(
            child: SwitchListTile(
              title: const Text('对外提供大模型服务'),
              subtitle: Text(
                running ? _service.baseUrl : '关闭中',
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
                            : () {
                                Clipboard.setData(
                                    ClipboardData(text: _keyController.text));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已复制')),
                                );
                              },
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
                            labelText: '监听端口（1024~65535）',
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

          // 接入信息
          const _SectionTitle('接入信息（其他 App 填这些）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoRow(context, 'Base URL', _service.baseUrl),
                  _infoRow(context, 'OpenAI 兼容',
                      'POST ${_service.baseUrl}/v1/chat/completions'),
                  _infoRow(context, '模型列表',
                      'GET ${_service.baseUrl}/v1/models'),
                  _infoRow(context, 'Anthropic 兼容',
                      'POST ${_service.baseUrl}/v1/messages'),
                  const Divider(),
                  Text(
                    '仅本机（127.0.0.1）可访问，不对局域网暴露；'
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

          // 调用统计
          const _SectionTitle('调用统计'),
          Card(
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w500),
            ),
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
