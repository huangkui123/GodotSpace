package com.picospatialanchor.helper

import android.Manifest
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.picospatialanchor.helper.permissions.PermissionUtils

class MainActivity : AppCompatActivity() {

    private lateinit var hostInput: EditText
    private lateinit var portInput: EditText
    private lateinit var widthInput: EditText
    private lateinit var heightInput: EditText
    private lateinit var fpsInput: EditText
    private lateinit var jpegQualityInput: EditText
    private lateinit var renderModeInput: EditText
    private lateinit var rawOutputCheck: CheckBox
    private lateinit var statusText: TextView
    private lateinit var defaultsText: TextView

    private var startAfterPermissionGrant = false

    private val uiHandler = Handler(Looper.getMainLooper())
    private val statusUpdater = object : Runnable {
        override fun run() {
            statusText.text = AnchorCaptureService.latestStatusMessage()
            uiHandler.postDelayed(this, STATUS_REFRESH_INTERVAL_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        hostInput = findViewById(R.id.input_host)
        portInput = findViewById(R.id.input_port)
        widthInput = findViewById(R.id.input_width)
        heightInput = findViewById(R.id.input_height)
        fpsInput = findViewById(R.id.input_fps)
        jpegQualityInput = findViewById(R.id.input_jpeg_quality)
        renderModeInput = findViewById(R.id.input_render_mode)
        rawOutputCheck = findViewById(R.id.check_raw_output)
        statusText = findViewById(R.id.text_status)
        defaultsText = findViewById(R.id.text_defaults)

        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        hostInput.setText(prefs.getString(PREF_HOST, "192.168.1.100"))
        portInput.setText(prefs.getInt(PREF_PORT, AnchorStreamConfig.DEFAULT_PORT).toString())
        widthInput.setText(prefs.getInt(PREF_WIDTH, AnchorStreamConfig.DEFAULT_WIDTH).toString())
        heightInput.setText(prefs.getInt(PREF_HEIGHT, AnchorStreamConfig.DEFAULT_HEIGHT).toString())
        fpsInput.setText(prefs.getInt(PREF_FPS, AnchorStreamConfig.DEFAULT_FPS).toString())
        jpegQualityInput.setText(prefs.getInt(PREF_JPEG_QUALITY, AnchorStreamConfig.DEFAULT_JPEG_QUALITY).toString())
        renderModeInput.setText(prefs.getInt(PREF_RENDER_MODE, AnchorStreamConfig.DEFAULT_RENDER_MODE).toString())
        rawOutputCheck.isChecked = prefs.getBoolean(
            PREF_OUTPUT_CAMERA_RAW_DATA,
            AnchorStreamConfig.DEFAULT_OUTPUT_CAMERA_RAW_DATA,
        )
        defaultsText.text = getString(
            R.string.stream_defaults_template,
            AnchorStreamConfig.DEFAULT_WIDTH,
            AnchorStreamConfig.DEFAULT_HEIGHT,
            AnchorStreamConfig.DEFAULT_FPS,
            AnchorStreamConfig.DEFAULT_JPEG_QUALITY,
            AnchorStreamConfig.DEFAULT_RENDER_MODE,
            if (AnchorStreamConfig.DEFAULT_OUTPUT_CAMERA_RAW_DATA) {
                getString(R.string.raw_mode)
            } else {
                getString(R.string.rectified_mode)
            },
        )

        findViewById<Button>(R.id.button_start).setOnClickListener {
            startAfterPermissionGrant = true
            if (PermissionUtils.checkPermission(this, requiredPermissions(), true) == PermissionUtils.CHECK_RESULT_OK) {
                startAfterPermissionGrant = false
                startStreaming()
            } else {
                statusText.text = getString(R.string.status_waiting_permission)
            }
        }

        findViewById<Button>(R.id.button_stop).setOnClickListener {
            startService(AnchorCaptureService.buildStopIntent(this))
        }
    }

    override fun onStart() {
        super.onStart()
        uiHandler.post(statusUpdater)
    }

    override fun onStop() {
        uiHandler.removeCallbacks(statusUpdater)
        super.onStop()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PermissionUtils.REQUEST_CODE || !startAfterPermissionGrant) {
            return
        }
        startAfterPermissionGrant = false
        if (PermissionUtils.isPermissionGranted(this, requiredPermissions())) {
            startStreaming()
        } else {
            statusText.text = getString(R.string.status_permission_denied)
        }
    }

    private fun startStreaming() {
        val host = hostInput.text.toString().trim()
        val port = portInput.text.toString().trim().toIntOrNull()
        val width = widthInput.text.toString().trim().toIntOrNull()
        val height = heightInput.text.toString().trim().toIntOrNull()
        val fps = fpsInput.text.toString().trim().toIntOrNull()
        val jpegQuality = jpegQualityInput.text.toString().trim().toIntOrNull()
        val renderMode = renderModeInput.text.toString().trim().toIntOrNull()
        val outputCameraRawData = rawOutputCheck.isChecked

        if (host.isBlank()) {
            statusText.text = getString(R.string.status_invalid_host)
            return
        }
        if (port == null || port !in 1..65535) {
            statusText.text = getString(R.string.status_invalid_port)
            return
        }
        if (width == null || width !in 320..4096) {
            statusText.text = getString(R.string.status_invalid_width)
            return
        }
        if (height == null || height !in 240..4096) {
            statusText.text = getString(R.string.status_invalid_height)
            return
        }
        if (fps == null || fps !in 5..60) {
            statusText.text = getString(R.string.status_invalid_fps)
            return
        }
        if (jpegQuality == null || jpegQuality !in 30..95) {
            statusText.text = getString(R.string.status_invalid_jpeg_quality)
            return
        }
        if (renderMode == null || renderMode !in 0..3) {
            statusText.text = getString(R.string.status_invalid_render_mode)
            return
        }

        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putString(PREF_HOST, host)
            .putInt(PREF_PORT, port)
            .putInt(PREF_WIDTH, width)
            .putInt(PREF_HEIGHT, height)
            .putInt(PREF_FPS, fps)
            .putInt(PREF_JPEG_QUALITY, jpegQuality)
            .putInt(PREF_RENDER_MODE, renderMode)
            .putBoolean(PREF_OUTPUT_CAMERA_RAW_DATA, outputCameraRawData)
            .apply()

        ContextCompat.startForegroundService(
            this,
            AnchorCaptureService.buildStartIntent(
                this,
                AnchorStreamConfig(
                    host = host,
                    port = port,
                    width = width,
                    height = height,
                    fps = fps,
                    jpegQuality = jpegQuality,
                    renderMode = renderMode,
                    outputCameraRawData = outputCameraRawData,
                ),
            ),
        )
        statusText.text = getString(R.string.status_starting)
    }

    private fun requiredPermissions(): Array<String> {
        val permissions = mutableListOf(Manifest.permission.CAMERA)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions += Manifest.permission.POST_NOTIFICATIONS
        }
        return permissions.toTypedArray()
    }

    companion object {
        private const val PREFS_NAME = "pico_spatial_anchor_prefs"
        private const val PREF_HOST = "receiver_host"
        private const val PREF_PORT = "receiver_port"
        private const val PREF_WIDTH = "stream_width"
        private const val PREF_HEIGHT = "stream_height"
        private const val PREF_FPS = "stream_fps"
        private const val PREF_JPEG_QUALITY = "stream_jpeg_quality"
        private const val PREF_RENDER_MODE = "stream_render_mode"
        private const val PREF_OUTPUT_CAMERA_RAW_DATA = "stream_output_camera_raw_data"
        private const val STATUS_REFRESH_INTERVAL_MS = 1_000L
    }
}
