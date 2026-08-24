package com.example.edge_ai_app

import android.app.ActivityManager
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                            result.success(mi.totalMem)
                        } catch (e: Exception) {
                            result.error("DEVICE_INFO_ERROR", e.message, null)
                        }
                    }
                    "getFreeDisk" -> {
                        try {
                            val path = call.argument<String>("path") ?: filesDir.absolutePath
                            val stat = StatFs(path)
                            result.success(stat.availableBytes)
                        } catch (e: Exception) {
                            result.error("DEVICE_INFO_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
