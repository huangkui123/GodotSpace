package com.picospatialanchor.helper

internal object PicoCameraCalibration {

    const val INTRINSICS_VALUE_ORDER = "cx_cy_fx_fy"
    const val INTRINSICS_VALUE_COUNT = 4
    const val MATRIX_4X4_SIZE = 16
    const val ULTRA_MODEL = "A9410"
    const val CAMERA_TO_HEAD_CONVENTION = "pico_4_ultra_rectified_cv_to_head_openxr_v1"
    const val RECTIFIED_HORIZONTAL_FOV_DEGREES = 76.35
    const val RECTIFIED_VERTICAL_FOV_DEGREES = 61.05

    /**
     * Capture SDK camera optical frame -> OpenXR head frame, in metres.
     * Matches PICO Integration 3.4.0 getCameraParametersNew: C * raw, where
     * C rotates the reference axes +90 degrees about Z and translates the origin.
     * See SpatialCalibration/camera_model.md for the pinned SDK binary analysis.
     * The input camera axes remain OpenCV (right, down, forward).
     */
    fun cameraToHeadCv(values: List<Double>): List<Double>? {
        if (!isValidExtrinsic(values)) return null
        val converted = listOf(
            -values[4], -values[5], -values[6], 0.05057 - values[7],
            values[0], values[1], values[2], 0.01874 + values[3],
            values[8], values[9], values[10], -0.05194 + values[11],
            0.0, 0.0, 0.0, 1.0,
        )
        // Reject wrong units or a different device/reference frame.
        if (listOf(3, 7, 11).sumOf { converted[it] * converted[it] } > 0.09) return null
        return converted
    }

    fun isValidFov(value: Double): Boolean {
        return value.isFinite() && value > MIN_FOV_DEGREES && value < MAX_FOV_DEGREES
    }

    fun isValidIntrinsics(values: List<Double>): Boolean {
        if (values.size != INTRINSICS_VALUE_COUNT || values.any { !it.isFinite() }) {
            return false
        }
        val cx = values[0]
        val cy = values[1]
        val fx = values[2]
        val fy = values[3]
        return cx >= 0.0 && cy >= 0.0 && fx > 0.0 && fy > 0.0
    }

    fun isValidExtrinsic(values: List<Double>): Boolean {
        if (values.size != MATRIX_4X4_SIZE || values.any { !it.isFinite() }) {
            return false
        }
        if (kotlin.math.abs(values[12]) > MATRIX_EPSILON ||
            kotlin.math.abs(values[13]) > MATRIX_EPSILON ||
            kotlin.math.abs(values[14]) > MATRIX_EPSILON ||
            kotlin.math.abs(values[15] - 1.0) > MATRIX_EPSILON
        ) {
            return false
        }
        val determinant =
            values[0] * (values[5] * values[10] - values[6] * values[9]) -
                values[1] * (values[4] * values[10] - values[6] * values[8]) +
                values[2] * (values[4] * values[9] - values[5] * values[8])
        if (kotlin.math.abs(determinant - 1.0) > MATRIX_DETERMINANT_EPSILON) return false
        for (a in 0..2) {
            for (b in 0..2) {
                val dot = (0..2).sumOf { values[it * 4 + a] * values[it * 4 + b] }
                if (kotlin.math.abs(dot - if (a == b) 1.0 else 0.0) > MATRIX_DETERMINANT_EPSILON) return false
            }
        }
        return true
    }

    private const val MATRIX_EPSILON = 1e-6
    private const val MATRIX_DETERMINANT_EPSILON = 1e-3
    private const val MIN_FOV_DEGREES = 1.0
    private const val MAX_FOV_DEGREES = 179.0
}
