package com.example.edge_ai_app

import android.app.ActivityManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // 进程被杀后 Service 自愈拉起的后台引擎让位：销毁后 HTTP 监听由
        // main() 的 init() 在 UI 引擎内重建（避免双引擎双监听/双模型加载）
        ApiKeepAliveService.destroyBackgroundEngine()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "edge_ai_app/device_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getTotalRam" -> {
                        try {
                            val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
                            val mi = ActivityManager.MemoryInfo()
                            am.getMemoryInfo(mi)
                            // totalMem = /proc/meminfo MemTotal（内核可见物理内存），
                            // 小于厂商标称值属正常（GPU/固件等保留内存）
                            result.success(mi.totalMem)
                        } catch (e: Exception) {
                            result.error("DEVICE_INFO_ERROR", e.message, null)
                        }
                    }
                    "getFreeDisk" -> {
                        val path = call.argument<String>("path") ?: filesDir.absolutePath
                        try {
                            // 优先用 getAllocatableBytes（含系统可清缓存，与系统设置
                            // "剩余空间"口径一致，也更符合大文件下载的真实可用空间）
                            val free: Long = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                val sm = getSystemService(StorageManager::class.java)
                                sm.getAllocatableBytes(sm.getUuidForPath(File(path)))
                            } else {
                                StatFs(path).availableBytes
                            }
                            result.success(free)
                        } catch (e: Exception) {
                            // 统计服务异常时回退到 StatFs 口径（当前空闲块）
                            try {
                                result.success(StatFs(path).availableBytes)
                            } catch (e2: Exception) {
                                result.error("DEVICE_INFO_ERROR", e2.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 三期：保活与引导（需求 §2/§4）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "edge_ai_app/keepalive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        // App 在前台交互时调用（开关切换），满足 Android 12+
                        // 后台启动前台服务的限制
                        val port = call.argument<Int>("port") ?: 0
                        val address = call.argument<String>("address") ?: "127.0.0.1"
                        try {
                            ApiKeepAliveService.start(this, port, address)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("KEEPALIVE_ERROR", e.message, null)
                        }
                    }
                    "stopService" -> {
                        ApiKeepAliveService.stop(this)
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "areNotificationsEnabled" -> {
                        // Android 13+ 通知运行时权限状态（拒绝时保活不受影响，仅无通知）
                        val nm = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
                        result.success(nm.areNotificationsEnabled())
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        // 标准系统 Intent（需求 §4.1：一键设置，用户可拒绝）
                        try {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // 部分 ROM 禁用该入口，回退到电池优化列表页
                            try {
                                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("KEEPALIVE_ERROR", e2.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
