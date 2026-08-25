// lib/features/settings/model_params_screen.dart
// 模型参数配置页（需求文档 §4）：每模型一套参数，
// 采样参数保存即生效；上下文参数（n_ctx/n_threads）保存后自动触发重载
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/model_params.dart';
import '../../core/services/model_params_service.dart';

class ModelParamsScreen extends StatefulWidget {
  final String modelId;
  final String modelName;

  const ModelParamsScreen({
    super.key,
    required this.modelId,
    required this.modelName,
  });

  @override
  State<ModelParamsScreen> createState() => _ModelParamsScreenState();
}

class _ModelParamsScreenState extends State<ModelParamsScreen> {
  final ModelParamsService _paramsService = ModelParamsService();

  late ModelParams _params;

  /// 表单值（控制器与滑块共享的中间态）
  late double _temperature;
  late double _topP;
  late double _repeatPenalty;
  late int _topK;
  late int _maxTokens;
  late int _nCtx;
  late int _nThreads;
  final TextEditingController _systemPromptController = TextEditingController();

  bool _initialized = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadParams();
  }

  Future<void> _loadParams() async {
    final params = await _paramsService.getParams(widget.modelId);
    if (!mounted) return;
    setState(() {
      _params = params;
      _temperature = params.temperature;
      _topP = params.topP;
      _repeatPenalty = params.repeatPenalty;
      _topK = params.topK;
      _maxTokens = params.maxTokens;
      _nCtx = params.nCtx;
      _nThreads = params.nThreads;
      _systemPromptController.text = params.systemPrompt;
      _initialized = true;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final next = ModelParams(
        temperature: _temperature,
        topK: _topK,
        topP: _topP,
        repeatPenalty: _repeatPenalty,
        maxTokens: _maxTokens,
        nCtx: _nCtx,
        nThreads: _nThreads,
        systemPrompt: _systemPromptController.text.trim().isEmpty
            ? ModelParams.defSystemPrompt
            : _systemPromptController.text.trim(),
      );
      // 返回 true = 上下文参数变化（触发方：ModelParamsService.notifyListeners
      // → ChatScreen 监听 → 引擎签名比对自动重载）
      await _paramsService.saveParams(widget.modelId, next);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(!next.sameContextSignature(_params)
              ? '已保存，正在自动重新加载模型…'
              : '已保存，下次生成生效'),
          duration: const Duration(seconds: 2),
        ));
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认'),
        content: const Text('将全部参数恢复为出厂默认值。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _temperature = ModelParams.defTemperature;
      _topP = ModelParams.defTopP;
      _repeatPenalty = ModelParams.defRepeatPenalty;
      _topK = ModelParams.defTopK;
      _maxTokens = ModelParams.defMaxTokens;
      _nCtx = ModelParams.defNCtx;
      _nThreads = ModelParams.defNThreads;
      _systemPromptController.text = ModelParams.defSystemPrompt;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型参数'),
        actions: [
          TextButton(
            onPressed: _resetDefaults,
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: !_initialized
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionTitle('模型', widget.modelName),
                const SizedBox(height: 8),

                _sectionTitle('采样参数', '保存后下次生成即时生效'),
                _sliderTile(
                  label: '温度 (temperature)',
                  description: '越高越随机，越低越确定',
                  value: _temperature,
                  min: ModelParams.minTemperature,
                  max: ModelParams.maxTemperature,
                  divisions: 40,
                  display: _temperature.toStringAsFixed(2),
                  onChanged: (v) => setState(() => _temperature = v),
                ),
                _intSliderTile(
                  label: 'Top-K',
                  description: '每步只从概率最高的 K 个 token 中采样',
                  value: _topK,
                  min: ModelParams.minTopK,
                  max: ModelParams.maxTopK,
                  display: '$_topK',
                  onChanged: (v) => setState(() => _topK = v),
                ),
                _sliderTile(
                  label: 'Top-P（核采样）',
                  description: '累积概率截断，1 为不截断',
                  value: _topP,
                  min: ModelParams.minTopP,
                  max: ModelParams.maxTopP,
                  divisions: 20,
                  display: _topP.toStringAsFixed(2),
                  onChanged: (v) => setState(() => _topP = v),
                ),
                _sliderTile(
                  label: '重复惩罚 (repeat_penalty)',
                  description: '抑制重复内容，1 为不惩罚',
                  value: _repeatPenalty,
                  min: ModelParams.minRepeatPenalty,
                  max: ModelParams.maxRepeatPenalty,
                  divisions: 20,
                  display: _repeatPenalty.toStringAsFixed(2),
                  onChanged: (v) => setState(() => _repeatPenalty = v),
                ),
                _intInputTile(
                  label: '最大生成长度 (max_tokens)',
                  description: '单次回复的最大 token 数',
                  value: _maxTokens,
                  min: ModelParams.minMaxTokens,
                  max: ModelParams.maxMaxTokens,
                  onChanged: (v) => setState(() => _maxTokens = v),
                ),
                const SizedBox(height: 16),

                _sectionTitle('上下文参数', '修改后保存将自动重新加载模型（约 5~30 秒）'),
                _intInputTile(
                  label: '上下文窗口 (n_ctx)',
                  description: '提示词 + 回复共享的 token 窗口，越大越占内存',
                  value: _nCtx,
                  min: ModelParams.minNCtx,
                  max: ModelParams.maxNCtx,
                  step: 256,
                  onChanged: (v) => setState(() => _nCtx = v),
                ),
                _intInputTile(
                  label: '推理线程数 (n_threads)',
                  description: 'CPU 推理线程，一般 4 为宜',
                  value: _nThreads,
                  min: ModelParams.minNThreads,
                  max: ModelParams.maxNThreads,
                  onChanged: (v) => setState(() => _nThreads = v),
                ),
                const SizedBox(height: 16),

                _sectionTitle('系统提示词', '对话中扮演的角色的设定'),
                const SizedBox(height: 8),
                TextField(
                  controller: _systemPromptController,
                  maxLines: 4,
                  maxLength: ModelParams.maxSystemPromptLength,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '例如：你是一个乐于助人的中文助手',
                  ),
                ),
                const SizedBox(height: 24),

                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? '保存中…' : '保存'),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _sectionTitle(String title, String subtitle) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ],
      );

  Widget _sliderTile({
    required String label,
    required String description,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          Text(display,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blue)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(description, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _intSliderTile({
    required String label,
    required String description,
    required int value,
    required int min,
    required int max,
    required String display,
    required ValueChanged<int> onChanged,
  }) {
    return _sliderTile(
      label: label,
      description: description,
      value: value.toDouble(),
      min: min.toDouble(),
      max: max.toDouble(),
      display: display,
      onChanged: (v) => onChanged(v.round()),
    );
  }

  Widget _intInputTile({
    required String label,
    required String description,
    required int value,
    required int min,
    required int max,
    int step = 1,
    required ValueChanged<int> onChanged,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 14)),
      subtitle: Text(description, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
      trailing: SizedBox(
        width: 120,
        child: TextField(
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          controller: TextEditingController(text: value.toString())
            ..selection = TextSelection.collapsed(
                offset: value.toString().length),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            errorText: value < min || value > max ? '范围 $min~$max' : null,
          ),
          maxLength: 5,
          onChanged: (raw) {
            final v = int.tryParse(raw);
            if (v != null && v >= min && v <= max) {
              // 吸附到步长（n_ctx 256 对齐）
              final aligned = step > 1 ? (v ~/ step) * step : v;
              final snapped = aligned < min ? min : aligned;
              if (snapped != v) {
                // 范围内但不满足步长 → 钳到步长网格
                onChanged(snapped);
              } else {
                onChanged(v);
              }
            }
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _systemPromptController.dispose();
    super.dispose();
  }
}
