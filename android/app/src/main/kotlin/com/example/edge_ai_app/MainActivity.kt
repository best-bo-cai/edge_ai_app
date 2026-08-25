package com.example.edge_ai_app

import android.app.ActivityManager
import android.os.Build
import android.os.StatFs
import android.os.storage.StorageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

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
    }
}
