package com.picospatialanchor.helper

import android.content.Intent

data class PicoCastConfig(
    val host: String,
    val controlPort: Int,
    val controlToken: String,
) {
    fun toIntent(intent: Intent): Intent {
        return intent
            .putExtra(EXTRA_HOST, host)
            .putExtra(EXTRA_CONTROL_PORT, controlPort)
            .putExtra(EXTRA_CONTROL_TOKEN, controlToken)
    }

    companion object {
        const val EXTRA_HOST = "extra_pico_cast_host"
        const val EXTRA_CONTROL_PORT = "extra_pico_cast_control_port"
        const val EXTRA_CONTROL_TOKEN = "extra_pico_cast_control_token"

        const val DEFAULT_CONTROL_PORT = 8788

        fun fromIntent(intent: Intent?): PicoCastConfig? {
            if (intent == null) {
                return null
            }
            val host = intent.getStringExtra(EXTRA_HOST)?.trim().orEmpty()
            val token = intent.getStringExtra(EXTRA_CONTROL_TOKEN)?.trim().orEmpty()
            val controlPort = intent.getIntExtra(EXTRA_CONTROL_PORT, DEFAULT_CONTROL_PORT)
            if (host.isBlank() || token.isBlank() || controlPort !in 1..65535) {
                return null
            }
            return PicoCastConfig(
                host = host,
                controlPort = controlPort,
                controlToken = token,
            )
        }
    }
}
