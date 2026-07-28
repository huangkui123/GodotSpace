package com.picospatialanchor.helper

internal object PicoCameraCalibration {

    const val INTRINSICS_VALUE_ORDER = "cx_cy_fx_fy"
    const val INTRINSICS_VALUE_COUNT = 4
    const val MATRIX_4X4_SIZE = 16

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
        return kotlin.math.abs(determinant - 1.0) <= MATRIX_DETERMINANT_EPSILON
    }

    private const val MATRIX_EPSILON = 1e-6
    private const val MATRIX_DETERMINANT_EPSILON = 1e-3
    private const val MIN_FOV_DEGREES = 1.0
    private const val MAX_FOV_DEGREES = 179.0
}
