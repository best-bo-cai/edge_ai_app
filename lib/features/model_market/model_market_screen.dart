// lib/features/model_market/model_market_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/device/device_capability_service.dart';
import '../../core/models/compatibility.dart';
import '../../core/models/hf_catalog_models.dart';
import '../../core/services/hf_api_service.dart';
import '../../core/services/model_service.dart';
import 'model_detail_screen.dart';
import 'widgets/compat_badge.dart';

/// 模型广场：HF 推荐列表 + 设备适配筛选 + 搜索分页 + 网络兜底（需求 2.2/2.3/3.1）
class ModelMarketScreen extends StatefulWidget {
  const ModelMarketScreen({super.key});

  @override
  State<ModelMarketScreen> createState() => _ModelMarketScreenState();
}

class _ModelMarketScreenState extends State<ModelMarketScreen> {
  final HfApiService _api = HfApiService();
  final ModelService _modelService = ModelService();
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();

  Timer? _debounce;
  DeviceCapability? _capability;
  List<HfModel> _models = [];
  bool _isFallback = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _skip = 0;
  String? _query;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _api.restoreHost().then((_) => _loadInitial());
  }

  void _onScroll() {
    if (_isFallback || !_hasMore || _loading || _loadingMore) return;
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
      _models = [];
      _skip = 0;
      _hasMore = true;
    });
    _capability ??= await DeviceCapabilityService().getCapability();
    try {
      final models = await _api.searchModels(query: _query);
      if (!mounted) return;
      setState(() {
        _models = models;
        _isFallback = false;
        _skip = models.length;
        _hasMore = models.length >= 30;
        _loading = false;
      });
    } catch (e) {
      // 网络异常兜底（需求 3.1）
      final fallback = await _modelService.loadFallbackModels();
      if (!mounted) return;
      setState(() {
        _isFallback = fallback.isNotEmpty;
        _models = fallback;
        _hasMore = false;
        _loading = false;
        if (fallback.isEmpty) _error = '加载失败：$e';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final more = await _api.searchModels(query: _query, skip: _skip);
      if (!mounted) return;
      setState(() {
        _models.addAll(more);
        _skip += more.length;
        _hasMore = more.length >= 30;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载更多失败，请检查网络')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _query = value.trim().isEmpty ? null : value.trim();
      _loadInitial();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('模型广场')),
      body: Column(
        children: [
          if (_capability != null) _buildCapabilityBanner(_capability!),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              enabled: !_isFallback,
              decoration: InputDecoration(
                hintText: _isFallback ? '离线模式，搜索不可用' : '搜索模型（如 qwen、llama）',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (_isFallback)
            Container(
              width: double.infinity,
              color: Colors.orange.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Text(
                '网络不可用，已展示离线推荐列表',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _ErrorView(message: _error!, onRetry: _loadInitial)
                    : RefreshIndicator(
                        onRefresh: _loadInitial,
                        child: ListView.builder(
                          controller: _scrollCtrl,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _models.length + (_hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _models.length) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2)),
                              );
                            }
                            final model = _models[index];
                            return _ModelCard(
                              model: model,
                              capability: _capability,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ModelDetailScreen(model: model),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  /// 本机配置横幅（需求 2.1 采集结果展示）
  Widget _buildCapabilityBanner(DeviceCapability cap) {
    final gb =
        (cap.assumedRamBytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.phone_android, size: 18, color: Colors.blue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '本机配置：${cap.isEstimated ? '≈' : ''}$gb GB 内存 · ${cap.cpuCores} 核 · ${cap.abi}'
                '${cap.freeDiskBytes != null ? ' · 可用存储 ${_fmtBytes(cap.freeDiskBytes!)}' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.capability,
    required this.onTap,
  });

  final HfModel model;
  final DeviceCapability? capability;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final level = capability == null
        ? CompatibilityLevel.unknown
        : CompatibilityEngine.evaluateModel(capability!, model);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      model.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CompatBadge(level: level),
                ],
              ),
              const SizedBox(height: 4),
              Text(model.author,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.download, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(_fmtCount(model.downloads),
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 16),
                  const Icon(Icons.favorite, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text('${model.likes}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey)),
                  const Spacer(),
                  ..._tagChips(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _tagChips() {
    final useful = model.tags
        .where((t) =>
            !t.contains(':') &&
            !['transformers', 'endpoints_compatible', 'conversational']
                .contains(t))
        .take(2);
    return [
      for (final t in useful)
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blueGrey.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(t,
                style:
                    const TextStyle(fontSize: 10, color: Colors.blueGrey)),
          ),
        ),
    ];
  }

  String _fmtCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey)),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
