package com.picospatialanchor.helper

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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class PicoCastService : Service() {

    private lateinit var executor: ExecutorService
    private lateinit var castProvider: PicoCastProvider
    private var currentConfig: PicoCastConfig? = null
    private var castStarted = false

    override fun onCreate() {
        super.onCreate()
        executor = Executors.newSingleThreadExecutor()
        castProvider = PicoCastProvider(this, ::onCastConnectionStateChanged)
        startForegroundWithStatus("等待开始 PICO 投屏")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = PicoCastConfig.fromIntent(intent)
                if (config == null) {
                    updateStatus("启动失败: 投屏接收端、端口或令牌无效")
                } else {
                    executor.execute { startCast(config) }
                }
            }

            ACTION_STOP -> executor.execute { stopCast(stopService = true) }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (::executor.isInitialized) {
            // Keep ToB calls and the control-channel notification serialized with
            // start/stop commands. Shutting the executor down after this task lets
            // an already queued start complete and then be deterministically stopped.
            executor.execute {
                stopCast(stopService = false)
                if (::castProvider.isInitialized) {
                    castProvider.unbind()
                }
                executor.shutdown()
            }
        } else if (::castProvider.isInitialized) {
            castProvider.unbind()
        }
        super.onDestroy()
    }

    private fun startCast(config: PicoCastConfig) {
        if (castStarted) {
            stopCast(stopService = false)
        }
        currentConfig = config
        updateStatus("正在初始化 PICO 投屏")
        val result = castProvider.start()
        if (!result.isSuccess) {
            currentConfig = null
            castProvider.stop()
            updateStatus("PICO 投屏启动失败: ${result.error ?: "未知错误"}")
            return
        }

        val rtmpUrl = result.rtmpUrl ?: return
        castStarted = true
        runCatching {
            PicoCastControlSender.publishLive(config, rtmpUrl)
        }.onSuccess {
            updateStatus(
                "投屏地址已发送到 ${config.host}:${config.controlPort}，等待 PC 连接",
            )
        }.onFailure { throwable ->
            updateStatus("投屏已启动，但上报失败: ${PicoCastControlSender.describeFailure(throwable)}")
        }
    }

    private fun onCastConnectionStateChanged(state: Int) {
        if (!::executor.isInitialized || executor.isShutdown) {
            return
        }
        executor.execute {
            if (!castStarted) {
                return@execute
            }
            updateStatus(
                when (state) {
                    CAST_CONNECTED -> "PICO 投屏连接已建立"
                    CAST_DISCONNECTED -> "PICO 投屏等待 PC 连接"
                    CAST_NO_MIC_PERMISSION -> "PICO 投屏异常: 缺少麦克风权限"
                    else -> "PICO 投屏状态未知: $state"
                },
            )
        }
    }

    private fun stopCast(stopService: Boolean) {
        val config = currentConfig
        val wasStarted = castStarted
        currentConfig = null
        castStarted = false
        if (wasStarted && config != null) {
            runCatching { PicoCastControlSender.publishStopped(config) }
        }
        val stopError = if (wasStarted) castProvider.stop() else null
        updateStatus(
            when {
                !wasStarted -> "PICO 投屏已停止"
                stopError == null -> "PICO 投屏已停止"
                else -> "停止 PICO 投屏失败: $stopError"
            },
        )
        if (stopService) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun startForegroundWithStatus(initialStatus: String) {
        createNotificationChannel()
        val notification = buildNotification(initialStatus)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        lastStatusMessage = initialStatus
    }

    private fun updateStatus(message: String) {
        lastStatusMessage = message
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(message))
    }

    private fun buildNotification(status: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            2,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            3,
            buildStopIntent(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(getString(R.string.pico_cast_notification_title))
            .setContentText(status)
            .setSmallIcon(R.drawable.ic_stat_stream)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(R.drawable.ic_stat_stream, getString(R.string.stop_pico_cast), stopIntent)
            .build()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            getString(R.string.pico_cast_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        private const val ACTION_START = "com.picospatialanchor.helper.action.START_PICO_CAST"
        private const val ACTION_STOP = "com.picospatialanchor.helper.action.STOP_PICO_CAST"
        private const val NOTIFICATION_CHANNEL_ID = "pico_cast_control"
        private const val NOTIFICATION_ID = 1002
        private const val CAST_DISCONNECTED = 0
        private const val CAST_CONNECTED = 1
        private const val CAST_NO_MIC_PERMISSION = 2

        @Volatile
        private var lastStatusMessage: String = "等待开始 PICO 投屏"

        fun buildStartIntent(context: Context, config: PicoCastConfig): Intent {
            return config.toIntent(
                Intent(context, PicoCastService::class.java).setAction(ACTION_START),
            )
        }

        fun buildStopIntent(context: Context): Intent {
            return Intent(context, PicoCastService::class.java).setAction(ACTION_STOP)
        }

        fun latestStatusMessage(): String = lastStatusMessage
    }
}
