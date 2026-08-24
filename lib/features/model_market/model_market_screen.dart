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
  final HfApiService _api = HfApiService.instance;
  final ModelService _modelService = ModelService();
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();

  /// 分页大小（M4：searchModels 的 limit 与 _hasMore 判断共用的单一定义点）
  static const int _pageSize = 30;

  Timer? _debounce;
  DeviceCapability? _capability;
  List<HfModel> _models = [];
  Map<String, CompatibilityLevel> _compatLevels = {};
  bool _isFallback = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  bool _hasMore = true;
  String? _error;
  int _skip = 0;
  String? _query;

  /// 异步竞态代际计数（I1）：每次 _loadInitial 递增，
  /// 旧请求返回时因代际不一致被丢弃，避免污染新列表与 _skip
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _api.restoreHost().then((_) {
      if (mounted) _loadInitial();
    });
  }

  void _onScroll() {
    if (_isFallback || !_hasMore || _loading || _loadingMore) return;
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
      _models = [];
      _compatLevels = {};
      _skip = 0;
      _hasMore = true;
      _loadMoreFailed = false;
    });
    _capability ??= await DeviceCapabilityService().getCapability();
    try {
      final (shown, consumed, hasMore) =
          await _fetchVisible(query: _query, skip: 0);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _models = shown;
        _compatLevels = _computeCompat(shown);
        _isFallback = false;
        _skip = consumed;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (e) {
      // 网络异常兜底（需求 3.1）
      final fallback = await _modelService.loadFallbackModels();
      if (!mounted || epoch != _epoch) return;
      final visibleFallback = _filterCompatible(fallback);
      setState(() {
        _isFallback = fallback.isNotEmpty;
        _models = visibleFallback;
        _compatLevels = _computeCompat(visibleFallback);
        _hasMore = false;
        _loading = false;
        if (fallback.isEmpty) _error = '加载失败：$e';
      });
    }
  }

  /// 过滤掉超出设备配置的模型（用户决策：无法运行的模型不展示）
  List<HfModel> _filterCompatible(List<HfModel> models) {
    final cap = _capability;
    if (cap == null) return models;
    return models
        .where((m) =>
            CompatibilityEngine.evaluateModel(cap, m) !=
            CompatibilityLevel.overkill)
        .toList();
  }

  /// 拉取并过滤一页数据；若整页都被过滤掉（热门榜常被大模型占据）则自动
  /// 向后多拉（首屏最多 3 页），避免出现空列表。返回：
  /// (可见模型, 已消费的原始条数, 是否可能还有下一页)
  Future<(List<HfModel>, int, bool)> _fetchVisible(
      {String? query, required int skip}) async {
    var consumed = 0;
    var hasMore = false;
    for (var page = 0; page <= 3; page++) {
      final raw = await _api.searchModels(
          query: query, limit: _pageSize, skip: skip + consumed);
      consumed += raw.length;
      hasMore = raw.length >= _pageSize;
      final shown = _filterCompatible(raw);
      if (shown.isNotEmpty || !hasMore) return (shown, consumed, hasMore);
    }
    return (const <HfModel>[], consumed, hasMore);
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    final epoch = _epoch;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final (shown, consumed, hasMore) =
          await _fetchVisible(query: _query, skip: _skip);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _models.addAll(shown);
        _compatLevels.addAll(_computeCompat(shown));
        _skip += consumed;
        _hasMore = hasMore;
      });
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _loadMoreFailed = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('加载更多失败，请检查网络')),
        );
      }
    } finally {
      // 无论代际是否变化都复位加载态，避免新会话被卡死在 _loadingMore
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 数据落地时预计算兼容等级（M3：避免 _ModelCard 每次 build 重跑正则）
  Map<String, CompatibilityLevel> _computeCompat(List<HfModel> models) {
    final cap = _capability;
    if (cap == null) return {};
    return {
      for (final m in models) m.id: CompatibilityEngine.evaluateModel(cap, m),
    };
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
                          itemCount: _models.isEmpty
                              ? 1
                              : _models.length +
                                  ((_loadingMore || _loadMoreFailed) ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (_models.isEmpty) {
                              // 搜索空结果空态（M2）：仍处于可滚动列表内，下拉刷新可用
                              return _EmptyView(
                                message: _query != null
                                    ? '未找到匹配模型'
                                    : '暂无适配本机配置的模型',
                              );
                            }
                            if (index >= _models.length) {
                              // 尾部项（M1）：加载中显示指示器，失败显示"点击重试"
                              if (_loadMoreFailed) {
                                return InkWell(
                                  onTap: _loadMore,
                                  child: const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(
                                      child: Text(
                                        '点击重试',
                                        style: TextStyle(color: Colors.blue),
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                              );
                            }
                            final model = _models[index];
                            return _ModelCard(
                              model: model,
                              level: _compatLevels[model.id] ??
                                  CompatibilityLevel.unknown,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ModelDetailScreen(model: model),
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
                '本机配置：${cap.isEstimated ? '≈' : ''}$gb GB 物理内存 · 模型可用约 ${_fmtBytes(cap.usableRamBytes)} · ${cap.cpuCores} 核 · ${cap.abi}'
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
    required this.level,
    required this.onTap,
  });

  final HfModel model;

  /// 预计算的兼容等级（M3：由列表数据落地时统一计算传入）
  final CompatibilityLevel level;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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

/// 空态视图（M2：搜索无结果时展示；作为列表项渲染以保留下拉刷新）
class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 96),
      child: Column(
        children: [
          const Icon(Icons.search_off, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
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
