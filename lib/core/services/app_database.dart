// lib/core/services/app_database.dart
// SQLite 持久化：会话/消息/模型参数/API 调用日志（需求文档 §2.2）
// sqflite 依赖自项目初始已声明，此前未启用。
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// 应用数据库（单例）。
/// 表结构见 docs/对话能力升级需求文档.md §2.2：
/// - conversations / messages：一期核心
/// - model_params：每模型一套推理参数（需求 3）
/// - api_call_logs：二期 API 服务调用日志，建表提前完成
class AppDatabase {
  static final AppDatabase _instance = AppDatabase._internal();
  factory AppDatabase() => _instance;
  AppDatabase._internal();

  Database? _db;

  static const int _dbVersion = 1;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'edge_ai_app.db'),
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            model_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            last_message TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        // 会话消息时间线查询（列表页摘要 + 会话内分页）
        await db.execute(
            'CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at)');
        await db.execute('''
          CREATE TABLE model_params (
            model_id TEXT PRIMARY KEY,
            params_json TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE api_call_logs (
            id TEXT PRIMARY KEY,
            endpoint TEXT NOT NULL,
            model_id TEXT,
            prompt_tokens INTEGER,
            output_tokens INTEGER,
            request_body TEXT,
            response_body TEXT,
            created_at INTEGER NOT NULL
          )
        ''');
      },
    );
  }
}
