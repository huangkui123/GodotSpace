package com.picospatialanchor.helper

import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Sends the PICO Cast session descriptor to the Godot ground-view receiver.
 *
 * This deliberately uses a separate small control channel, rather than
 * extending the PSA2 camera-frame protocol on port 8787.
 */
object PicoCastControlSender {

    private const val TAG = "PicoCastControlSender"
    private const val CONNECT_TIMEOUT_MS = 3_000
    private const val PROTOCOL_VERSION = 1
    private const val MESSAGE_TYPE = "pico_cast_session"

    fun publishLive(config: PicoCastConfig, rtmpUrl: String) {
        val payload = JSONObject()
            .put("version", PROTOCOL_VERSION)
            .put("type", MESSAGE_TYPE)
            .put("state", "live")
            .put("authorization", config.controlToken)
            .put("rtmp_url", rtmpUrl)
            .put("device_name", Build.MODEL ?: "PICO")
            .put("audio_enabled", false)
            .put("timestamp_msec", System.currentTimeMillis())
        send(config, payload)
    }

    fun publishStopped(config: PicoCastConfig) {
        val payload = JSONObject()
            .put("version", PROTOCOL_VERSION)
            .put("type", MESSAGE_TYPE)
            .put("state", "stopped")
            .put("authorization", config.controlToken)
            .put("device_name", Build.MODEL ?: "PICO")
            .put("timestamp_msec", System.currentTimeMillis())
        send(config, payload)
    }

    private fun send(config: PicoCastConfig, payload: JSONObject) {
        val packet = (payload.toString() + "\n").toByteArray(Charsets.UTF_8)
        Socket().use { socket ->
            socket.tcpNoDelay = true
            socket.connect(
                InetSocketAddress(config.host, config.controlPort),
                CONNECT_TIMEOUT_MS,
            )
            BufferedOutputStream(socket.getOutputStream()).use { output ->
                output.write(packet)
                output.flush()
            }
        }
    }

    fun describeFailure(throwable: Throwable): String {
        Log.w(TAG, "PICO Cast control publish failed", throwable)
        val detail = throwable.message?.take(100).orEmpty()
        return if (detail.isEmpty()) {
            throwable.javaClass.simpleName
        } else {
            "${throwable.javaClass.simpleName}: $detail"
        }
    }
}
