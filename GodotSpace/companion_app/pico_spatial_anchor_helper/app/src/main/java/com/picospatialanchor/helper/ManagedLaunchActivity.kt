package com.picospatialanchor.helper

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.TextView
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File

/** Brief visible entrypoint: Android camera FGS must start from a visible app. */
class ManagedLaunchActivity : Activity() {
    private var config: JSONObject? = null
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply { textSize = 22f; setPadding(32, 32, 32, 32) }
        setContentView(status)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        runCatching {
            val session = intent.getStringExtra("session_id").orEmpty()
            require(session.matches(Regex("[a-f0-9]{32}"))) { "Invalid session" }
            val prefs = getSharedPreferences("managed_session", MODE_PRIVATE)
            if (intent.action == ACTION_STOP) {
                if (prefs.getString("session_id", "") == session) {
                    stopService(Intent(this, AnchorCaptureService::class.java))
                    stopService(Intent(this, PicoCastService::class.java))
                    prefs.edit().clear().apply()
                    report(session, "stopped", "采集与投屏已停止")
                }
                finish()
                return
            }
            val file = File(getExternalFilesDir(null), "launch-$session.json")
            require(file.isFile && file.length() in 1..65536) { "Launch configuration missing" }
            val request = JSONObject(file.readText())
            file.delete()
            require(request.getString("session_id") == session) { "Session mismatch" }
            require(request.getInt("version") == 1) { "Unsupported launch version" }
            config = request
            val needed = mutableListOf<String>()
            if (request.optBoolean("capture", true)) needed += Manifest.permission.CAMERA
            if (request.optBoolean("cast", true)) needed += Manifest.permission.RECORD_AUDIO
            if (Build.VERSION.SDK_INT >= 33) needed += Manifest.permission.POST_NOTIFICATIONS
            val missing = needed.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
            if (missing.isNotEmpty()) {
                report(session, "permission", "请在头显内完成相机 / 投屏权限授权")
                requestPermissions(missing.toTypedArray(), 42)
            } else {
                startManagedSession()
            }
        }.onFailure {
            val session = intent.getStringExtra("session_id").orEmpty()
            if (session.matches(Regex("[a-f0-9]{32}"))) {
                report(session, "failed", "自动启动失败：${it.message}")
            } else {
                status.text = "自动启动失败：${it.message}"
            }
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code != 42) return
        if (results.isNotEmpty() && results.all { it == PackageManager.PERMISSION_GRANTED }) {
            startManagedSession()
        } else {
            config?.let { report(it.getString("session_id"), "failed", "权限未授予，请授权后在 PC 点击重试采集 / 投屏") }
        }
    }

    private fun startManagedSession() {
        val request = config ?: return
        val session = request.getString("session_id")
        runCatching {
            val localHost = request.getString("capture_host")
            val serverHost = request.getString("server_host")
            require(localHost.isNotBlank() && serverHost.isNotBlank())
            val token = request.optString("cast_token")
            if (request.optBoolean("cast", true)) {
                require(token.matches(Regex("[a-f0-9]{48}"))) { "Invalid cast token" }
            }
            if (request.optBoolean("capture", true)) {
                ContextCompat.startForegroundService(this, AnchorCaptureService.buildStartIntent(this,
                    AnchorStreamConfig(host = localHost, port = 8789,
                        secondaryHost = serverHost, secondaryPort = 8787)))
            } else {
                stopService(Intent(this, AnchorCaptureService::class.java))
            }
            if (request.optBoolean("cast", true)) {
                ContextCompat.startForegroundService(this, PicoCastService.buildStartIntent(this,
                    PicoCastConfig(serverHost, 8788, token)))
            } else {
                stopService(Intent(this, PicoCastService::class.java))
            }
            getSharedPreferences("managed_session", MODE_PRIVATE).edit().putString("session_id", session).apply()
            report(session, "started", "采集与投屏启动指令已提交，等待 PC 收到画面")
            Handler(Looper.getMainLooper()).postDelayed({ finish() }, 700)
        }.onFailure { report(session, "failed", "启动失败：${it.message}") }
    }

    private fun report(session: String, state: String, message: String) {
        status.text = message
        val file = File(getExternalFilesDir(null), "managed-status.json")
        file.writeText(JSONObject().put("session_id", session).put("state", state).put("message", message).toString())
    }

    companion object {
        const val ACTION_STOP = "com.picospatialanchor.helper.MANAGED_STOP"
    }
}
