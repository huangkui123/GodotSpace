package com.picospatialanchor.helper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.pxr.capturelib.PXRCapture
import com.pxr.capturelib.PXRCaptureCallBack
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class AnchorCaptureService : Service() {

    private lateinit var captureThread: HandlerThread
    private lateinit var captureHandler: Handler

    private var imageReader: ImageReader? = null
    private var pxrCapture: PXRCapture? = null
    private var sender: AnchorFrameSender? = null
    private var secondarySender: AnchorFrameSender? = null
    private var currentConfig: AnchorStreamConfig? = null
    private val cameraMetadataCollector = PicoCaptureMetadataCollector()
    private lateinit var headPoseProvider: PicoHeadPoseProvider

    private var previewStarted = false
    private var lastEncodedTimestampNs = 0L
    private val nextFrameId = AtomicInteger(1)

    private val imageListener = ImageReader.OnImageAvailableListener { reader ->
        val config = currentConfig ?: return@OnImageAvailableListener
        val image = reader.acquireLatestImage() ?: return@OnImageAvailableListener

        try {
            val minFrameIntervalNs = if (config.fps > 0) 1_000_000_000L / config.fps else 0L
            if (minFrameIntervalNs > 0L &&
                lastEncodedTimestampNs > 0L &&
                image.timestamp - lastEncodedTimestampNs < minFrameIntervalNs
            ) {
                return@OnImageAvailableListener
            }
            val jpegBytes = image.toJpeg(config.jpegQuality)
            val headPoseSnapshot = headPoseProvider.snapshot()
            val metadataBytes = cameraMetadataCollector.buildMetadataBytes(
                capture = pxrCapture,
                config = config,
                frameWidth = image.width,
                frameHeight = image.height,
                imageFormat = image.format,
                imagePlanes = buildImagePlaneMetadata(image),
                frameTimestampNs = image.timestamp,
                headPoseSnapshot = headPoseSnapshot,
            )
            val frameId = nextFrameId.getAndIncrement()
            sender?.offer(
                frameId = frameId,
                timestampNs = image.timestamp,
                width = image.width,
                height = image.height,
                metadataBytes = metadataBytes,
                jpegBytes = jpegBytes,
            )
            // One capture and JPEG encode, independent bounded network queues.
            secondarySender?.offer(frameId, image.timestamp, image.width, image.height, metadataBytes, jpegBytes)
            lastEncodedTimestampNs = image.timestamp
        } catch (error: Throwable) {
            reportThrowable("取帧失败", error)
        } finally {
            image.close()
        }
    }

    private val captureCallback = object : PXRCaptureCallBack {
        override fun captureOnStateChanged(state: Int) {
            captureHandler.post {
                runSafely("处理状态回调 state=$state") {
                    handleCaptureState(state)
                }
            }
        }

        override fun captureOnError(error: Int) {
            captureHandler.post {
                updateStatus("PXR Capture 错误: $error")
            }
        }

        override fun captureOnEnviromentInfoChanged(lut: Int, distance: Int) {
        }

        override fun captureOnTakePictureComplete(
            disparityScale: Float,
            disparityShift: Float,
            hfov: Float,
            vFov: Float,
            cameraIpd: Float,
        ) {
        }

        override fun captureOnTakePictureTimeOut() {
        }
    }

    override fun onCreate() {
        super.onCreate()
        headPoseProvider = PicoHeadPoseProvider(this).also { it.start() }
        captureThread = HandlerThread("anchor-capture-service")
        captureThread.uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, throwable ->
            reportThrowable("采集线程未捕获异常", throwable)
        }
        captureThread.start()
        captureHandler = Handler(captureThread.looper)
        startForegroundWithStatus("等待开始推流")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = AnchorStreamConfig.fromIntent(intent)
                if (config == null) {
                    updateStatus("启动失败: 缺少接收端地址")
                } else {
                    captureHandler.post {
                        runSafely("开始推流") {
                            startStreamingInternal(config)
                        }
                    }
                }
            }

            ACTION_STOP -> {
                captureHandler.post {
                    runSafely("停止推流") {
                        stopStreamingInternal()
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (::captureHandler.isInitialized) {
            val latch = CountDownLatch(1)
            captureHandler.post {
                stopStreamingInternal()
                latch.countDown()
            }
            runCatching { latch.await(1500, TimeUnit.MILLISECONDS) }
            captureThread.quitSafely()
        }
        if (::headPoseProvider.isInitialized) {
            headPoseProvider.stop()
        }
        lastStatusMessage = "服务已停止"
        super.onDestroy()
    }

    private fun startStreamingInternal(config: AnchorStreamConfig) {
        stopStreamingInternal()
        currentConfig = config
        previewStarted = false
        lastEncodedTimestampNs = 0L
        nextFrameId.set(1)

        imageReader = ImageReader.newInstance(
            config.width,
            config.height,
            PixelFormat.RGBA_8888,
            2,
        ).apply {
            setOnImageAvailableListener(imageListener, captureHandler)
        }

        sender = AnchorFrameSender(config.host, config.port, ::updateStatus).also { it.start() }
        if (config.secondaryHost.isNotBlank() && config.secondaryPort in 1..65535 &&
            (config.secondaryHost != config.host || config.secondaryPort != config.port)
        ) {
            secondarySender = AnchorFrameSender(config.secondaryHost, config.secondaryPort) { message ->
                Log.d(TAG, "Shared receiver: $message")
            }.also { it.start() }
        }

        pxrCapture = PXRCapture().apply {
            setCallback(captureCallback)
            openCameraAsync(
                hashMapOf(
                    PXRCapture.CAMERA_PARAMS_KEY_MCTF to PXRCapture.VALUE_FALSE,
                    PXRCapture.CAMERA_PARAMS_KEY_EIS to PXRCapture.VALUE_FALSE,
                    PXRCapture.CAMERA_PARAMS_KEY_MFNR to PXRCapture.VALUE_FALSE,
                ),
            )
        }

        updateStatus("正在打开相机")
    }

    private fun handleCaptureState(state: Int) {
        val config = currentConfig
        if (config == null) {
            return
        }

        when (state) {
            PXRCapture.PXRCaptureState.CAPTURE_STATE_CAMERA_OPENED.ordinal -> {
                pxrCapture?.configure(
                    hashMapOf(
                        PXRCapture.CONFIGURE_PARAMS_KEY_ENABLE_MVHEVC to PXRCapture.VALUE_FALSE,
                        PXRCapture.CONFIGURE_PARAMS_KEY_VIDEO_FPS to config.fps.toString(),
                        PXRCapture.CONFIGURE_PARAMS_KEY_VIDEO_WIDTH to config.width.toString(),
                        PXRCapture.CONFIGURE_PARAMS_KEY_VIDEO_HEIGHT to config.height.toString(),
                        PXRCapture.CONFIGURE_PARAMS_KEY_VIDEO_BITRATE to (10 * 1024 * 1024).toString(),
                        KEY_OUTPUT_CAMERA_RAW_DATA to (
                            if (config.outputCameraRawData) {
                                PXRCapture.VALUE_TRUE
                            } else {
                                PXRCapture.VALUE_FALSE
                            }
                        ),
                    ),
                )
                updateStatus("相机已打开，正在配置反畸变采集")
            }

            PXRCapture.PXRCaptureState.CAPTURE_STATE_CONFIGURED.ordinal -> {
                if (previewStarted) {
                    updateStatus("采集已停止")
                    return
                }
                val previewSurface = imageReader?.surface
                if (previewSurface == null) {
                    updateStatus("预览 surface 不存在")
                    return
                }
                pxrCapture?.startPreview(
                    previewSurface,
                    config.renderMode,
                    config.width,
                    config.height,
                )
                previewStarted = true
                updateStatus("预览已启动，等待 Godot 接收")
            }

            PXRCapture.PXRCaptureState.CAPTURE_STATE_VIDEO_PREVIEWING.ordinal -> {
                updateStatus("正在推流到 ${config.host}:${config.port}")
            }

            else -> Unit
        }
    }

    private fun stopStreamingInternal() {
        secondarySender?.stop()
        secondarySender = null
        sender?.stop()
        sender = null

        pxrCapture?.run {
            runCatching { stopPreview() }
            runCatching { reset() }
            runCatching { closeCamera() }
            runCatching { release() }
        }
        pxrCapture = null
        previewStarted = false
        lastEncodedTimestampNs = 0L

        imageReader?.setOnImageAvailableListener(null, null)
        imageReader?.close()
        imageReader = null
        currentConfig = null

        updateStatus("等待开始推流")
    }

    private fun buildImagePlaneMetadata(image: android.media.Image): JSONArray {
        val planes = JSONArray()
        image.planes.forEachIndexed { index, plane ->
            planes.put(
                JSONObject()
                    .put("index", index)
                    .put("row_stride", plane.rowStride)
                    .put("pixel_stride", plane.pixelStride)
                    .put("buffer_remaining", plane.buffer.remaining())
            )
        }
        return planes
    }

    private fun runSafely(stage: String, block: () -> Unit) {
        try {
            block()
        } catch (throwable: Throwable) {
            reportThrowable(stage, throwable)
        }
    }

    private fun reportThrowable(stage: String, throwable: Throwable) {
        val detail = throwable.message?.take(120).orEmpty()
        val status = buildString {
            append(stage)
            append(": ")
            append(throwable.javaClass.simpleName)
            if (detail.isNotBlank()) {
                append(" - ")
                append(detail)
            }
        }
        Log.e(TAG, status, throwable)
        runCatching { updateStatus(status) }
    }

    private fun startForegroundWithStatus(initialStatus: String) {
        createNotificationChannel()
        val notification = buildNotification(initialStatus)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        lastStatusMessage = initialStatus
    }

    private fun updateStatus(message: String) {
        lastStatusMessage = message
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(message))
    }

    private fun buildNotification(status: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            buildStopIntent(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(status)
            .setSmallIcon(R.drawable.ic_stat_stream)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(R.drawable.ic_stat_stream, getString(R.string.stop_streaming), stopIntent)
            .build()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val ACTION_START = "com.picospatialanchor.helper.action.START_STREAMING"
        private const val ACTION_STOP = "com.picospatialanchor.helper.action.STOP_STREAMING"
        private const val KEY_OUTPUT_CAMERA_RAW_DATA = "output-camera-raw-data"
        private const val NOTIFICATION_CHANNEL_ID = "pico_spatial_anchor"
        private const val NOTIFICATION_ID = 1001
        private const val TAG = "AnchorCaptureService"

        @Volatile
        private var lastStatusMessage: String = "等待开始推流"

        fun buildStartIntent(context: Context, config: AnchorStreamConfig): Intent {
            return config.toIntent(Intent(context, AnchorCaptureService::class.java).setAction(ACTION_START))
        }

        fun buildStopIntent(context: Context): Intent {
            return Intent(context, AnchorCaptureService::class.java).setAction(ACTION_STOP)
        }

        fun latestStatusMessage(): String = lastStatusMessage
    }
}
