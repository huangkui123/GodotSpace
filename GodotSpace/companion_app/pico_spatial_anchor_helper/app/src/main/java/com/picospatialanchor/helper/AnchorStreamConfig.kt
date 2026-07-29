package com.picospatialanchor.helper

import android.content.Intent

data class AnchorStreamConfig(
    val host: String,
    val port: Int,
    val width: Int = DEFAULT_WIDTH,
    val height: Int = DEFAULT_HEIGHT,
    val fps: Int = DEFAULT_FPS,
    val jpegQuality: Int = DEFAULT_JPEG_QUALITY,
    val renderMode: Int = DEFAULT_RENDER_MODE,
    val outputCameraRawData: Boolean = DEFAULT_OUTPUT_CAMERA_RAW_DATA,
    val horizontalFovDegrees: Double = DEFAULT_HORIZONTAL_FOV_DEGREES,
    val verticalFovDegrees: Double = DEFAULT_VERTICAL_FOV_DEGREES,
) {
    fun toIntent(intent: Intent): Intent {
        return intent
            .putExtra(EXTRA_HOST, host)
            .putExtra(EXTRA_PORT, port)
            .putExtra(EXTRA_WIDTH, width)
            .putExtra(EXTRA_HEIGHT, height)
            .putExtra(EXTRA_FPS, fps)
            .putExtra(EXTRA_JPEG_QUALITY, jpegQuality)
            .putExtra(EXTRA_RENDER_MODE, renderMode)
            .putExtra(EXTRA_OUTPUT_CAMERA_RAW_DATA, outputCameraRawData)
            .putExtra(EXTRA_HORIZONTAL_FOV_DEGREES, horizontalFovDegrees)
            .putExtra(EXTRA_VERTICAL_FOV_DEGREES, verticalFovDegrees)
    }

    companion object {
        const val EXTRA_HOST = "extra_host"
        const val EXTRA_PORT = "extra_port"
        const val EXTRA_WIDTH = "extra_width"
        const val EXTRA_HEIGHT = "extra_height"
        const val EXTRA_FPS = "extra_fps"
        const val EXTRA_JPEG_QUALITY = "extra_jpeg_quality"
        const val EXTRA_RENDER_MODE = "extra_render_mode"
        const val EXTRA_OUTPUT_CAMERA_RAW_DATA = "extra_output_camera_raw_data"
        const val EXTRA_HORIZONTAL_FOV_DEGREES = "extra_horizontal_fov_degrees"
        const val EXTRA_VERTICAL_FOV_DEGREES = "extra_vertical_fov_degrees"

        const val DEFAULT_PORT = 8787
        const val DEFAULT_WIDTH = 960
        const val DEFAULT_HEIGHT = 720
        const val DEFAULT_FPS = 12
        const val DEFAULT_JPEG_QUALITY = 60
        const val DEFAULT_RENDER_MODE = 0
        const val DEFAULT_OUTPUT_CAMERA_RAW_DATA = false
        const val DEFAULT_HORIZONTAL_FOV_DEGREES = 90.0
        const val DEFAULT_VERTICAL_FOV_DEGREES = 73.73979529168804

        fun fromIntent(intent: Intent?): AnchorStreamConfig? {
            if (intent == null) {
                return null
            }
            val host = intent.getStringExtra(EXTRA_HOST)?.trim().orEmpty()
            if (host.isBlank()) {
                return null
            }
            return AnchorStreamConfig(
                host = host,
                port = intent.getIntExtra(EXTRA_PORT, DEFAULT_PORT),
                width = intent.getIntExtra(EXTRA_WIDTH, DEFAULT_WIDTH),
                height = intent.getIntExtra(EXTRA_HEIGHT, DEFAULT_HEIGHT),
                fps = intent.getIntExtra(EXTRA_FPS, DEFAULT_FPS),
                jpegQuality = intent.getIntExtra(EXTRA_JPEG_QUALITY, DEFAULT_JPEG_QUALITY),
                renderMode = intent.getIntExtra(EXTRA_RENDER_MODE, DEFAULT_RENDER_MODE),
                outputCameraRawData = intent.getBooleanExtra(
                    EXTRA_OUTPUT_CAMERA_RAW_DATA,
                    DEFAULT_OUTPUT_CAMERA_RAW_DATA,
                ),
                horizontalFovDegrees = intent.getDoubleExtra(
                    EXTRA_HORIZONTAL_FOV_DEGREES,
                    DEFAULT_HORIZONTAL_FOV_DEGREES,
                ),
                verticalFovDegrees = intent.getDoubleExtra(
                    EXTRA_VERTICAL_FOV_DEGREES,
                    DEFAULT_VERTICAL_FOV_DEGREES,
                ),
            )
        }
    }
}
