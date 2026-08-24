// lib/main.dart
import 'package:flutter/material.dart';
import 'features/chat/chat_screen.dart';
import 'features/settings/model_management_screen.dart';
import 'core/services/model_service.dart';
import 'core/services/download_manager.dart';
import 'core/services/hf_api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化模型服务
  final modelService = ModelService();
  await modelService.init();

  // 恢复下载任务记录（断点续传）
  await DownloadManager.instance.init();

  // 恢复上次可用的 HF 数据源（官方源/镜像），使镜像状态全局共享（首屏提速）
  await HfApiService.instance.restoreHost();

  runApp(const EdgeMindApp());
}

class EdgeMindApp extends StatelessWidget {
  const EdgeMindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalChat MVP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.grey[50],
        ),
      ),
      home: const HomePage(),
    );
  }
}

/// 主页 - 包含聊天界面和模型管理入口
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  
  final List<Widget> _pages = [
    const ChatScreen(),
    const ModelManagementScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat),
            label: '对话',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder),
            label: '模型',
          ),
        ],
      ),
    );
  }
}
