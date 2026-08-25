// lib/core/services/model_params_service.dart
// 模型参数服务：读写每模型参数（SQLite model_params 表），
// 参数变更时广播事件（ChatScreen 监听后触发按需重载）
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/model_params.dart';
import 'app_database.dart';

class ModelParamsService extends ChangeNotifier {
  static final ModelParamsService _instance = ModelParamsService._internal();
  factory ModelParamsService() => _instance;
  ModelParamsService._internal();

  /// 内存缓存（model_id → params），避免每条消息生成前都查库
  final Map<String, ModelParams> _cache = {};

  Map<String, ModelParams> get cache => Map.unmodifiable(_cache);

  /// 读取模型参数（无记录时返回出厂默认值并缓存）
  Future<ModelParams> getParams(String modelId) async {
    final cached = _cache[modelId];
    if (cached != null) return cached;

    final db = await AppDatabase().database;
    final rows = await db.query('model_params',
        where: 'model_id = ?', whereArgs: [modelId], limit: 1);
    final params = rows.isEmpty
        ? ModelParams.defaults
        : ModelParams.fromJson(
            _decode(rows.first['params_json'] as String));
    _cache[modelId] = params;
    return params;
  }

  /// 保存模型参数并广播。
  /// 返回值：true = 上下文参数（n_ctx/n_threads）发生变化（调用方需触发重载）
  Future<bool> saveParams(String modelId, ModelParams params) async {
    final old = await getParams(modelId);
    final db = await AppDatabase().database;
    await db.insert('model_params', {
      'model_id': modelId,
      'params_json': params.encode(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    _cache[modelId] = params;
    notifyListeners();
    return !old.sameContextSignature(params);
  }

  /// 删除模型时级联清理参数（需求文档 §4.4：不留孤儿数据）
  Future<void> deleteParams(String modelId) async {
    _cache.remove(modelId);
    final db = await AppDatabase().database;
    await db.delete('model_params', where: 'model_id = ?', whereArgs: [modelId]);
    notifyListeners();
  }

  /// 同步读缓存（引擎生成路径使用；未缓存时回退默认值——
  /// 正常流程 sendMessage 前必有 ensureLoaded 已预热缓存）
  ModelParams paramsOf(String modelId) => _cache[modelId] ?? ModelParams.defaults;

  Map<String, dynamic> _decode(String raw) {
    try {
      final v = const JsonCodec().decode(raw);
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }
}
