package com.example.edge_ai_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * API 服务保活前台服务（三期需求 §2，ADR-0003）：
 * - 生命周期与 ApiServerService（Dart 侧 HTTP 服务）严格绑定：start/stop 由 Dart 调用
 * - specialUse 类型：Android 15+ 对 dataSync 有 6 小时/天限时，本应用为常驻本地
 *   LLM API 服务器，选用 specialUse（侧载分发，无 Play 商店审核顾虑）
 * - START_STICKY：进程被系统极端回收后自动重启服务（intent == null 路径），
 *   此时拉起后台 FlutterEngine 执行 apiServerMain 入口恢复 HTTP 监听；
 *   用户打开 App 时 MainActivity 销毁后台引擎，由 main() 重建（同一条恢复路径）
 */
class ApiKeepAliveService : Service() {

    companion object {
        const val CHANNEL_ID = "api_server_keepalive"
        const val NOTIFICATION_ID = 1001

        /**
         * 自愈路径拉起的后台引擎。静态持有以便 MainActivity 打开 App 时销毁，
         * 避免与 UI 引擎形成双 HTTP 监听/双模型加载。
         */
        @Volatile
        var backgroundEngine: FlutterEngine? = null
            private set

        fun start(context: Context, port: Int, address: String) {
            val intent = Intent(context, ApiKeepAliveService::class.java).apply {
                putExtra("port", port)
                putExtra("address", address)
            }
            // API 26+ 必须 startForegroundService（App 在前台时调用，天然满足
            // Android 12+ 后台启动前台服务的限制）
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ApiKeepAliveService::class.java))
        }

        /** 用户打开 App（MainActivity.onCreate）时调用：让位给 UI 引擎 */
        fun destroyBackgroundEngine() {
            backgroundEngine?.let {
                it.destroy()
            }
            backgroundEngine = null
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            // START_STICKY 重启：进程刚被系统回收，Dart 侧 HTTP 服务已死，
            // 拉起后台引擎恢复（通知地址用上次值不可得，展示通用文案）
            startAsForeground(0, "")
            startBackgroundEngine()
        } else {
            val port = intent.getIntExtra("port", 0)
            val address = intent.getStringExtra("address") ?: "127.0.0.1"
            startAsForeground(port, address)
        }
        return START_STICKY
    }

    /** 后台 FlutterEngine 执行 apiServerMain（后台入口只起 HTTP 服务，无 UI） */
    private fun startBackgroundEngine() {
        if (backgroundEngine != null) return
        try {
            val engine = FlutterEngine(this)
            val appBundlePath =
                FlutterInjector.instance().flutterLoader().findAppBundlePath()
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(appBundlePath, "apiServerMain")
            )
            backgroundEngine = engine
        } catch (e: Exception) {
            // 引擎拉起失败（如 AOT 入口缺失）时服务仍保持前台，等待用户打开 App 自愈
            android.util.Log.e("ApiKeepAliveService", "background engine failed", e)
        }
    }

    override fun onDestroy() {
        // 服务停止（用户关开关）时后台引擎一并销毁，避免泄漏
        destroyBackgroundEngine()
        super.onDestroy()
    }

    private fun startAsForeground(port: Int, address: String) {
        createChannel()

        val contentIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val text = if (port > 0) {
            getString(R.string.keepalive_notification_text, address, port)
        } else {
            getString(R.string.keepalive_notification_title)
        }

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle(getString(R.string.keepalive_notification_title))
            .setContentText(text)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW) // 不发声不打扰
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+：声明 FGS 类型为 specialUse，需在 manifest 中同步声明 subtype
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.keepalive_channel_name),
                NotificationManager.IMPORTANCE_LOW // low：不弹横幅不出声
            ).apply {
                description = getString(R.string.keepalive_channel_desc)
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
}
