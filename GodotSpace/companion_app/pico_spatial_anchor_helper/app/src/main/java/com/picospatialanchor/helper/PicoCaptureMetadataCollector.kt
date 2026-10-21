package com.picospatialanchor.helper

import android.graphics.ImageFormat
import android.graphics.PixelFormat
import android.os.Build
import com.pxr.capturelib.PXRCapture
import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.Method

class PicoCaptureMetadataCollector {

    private val intrinsicsMethod: Method? = runCatching {
        PXRCapture::class.java.getMethod(
            METHOD_GET_CAMERA_INTRINSICS,
            Int::class.javaPrimitiveType!!,
            Int::class.javaPrimitiveType!!,
            Double::class.javaPrimitiveType!!,
            Double::class.javaPrimitiveType!!,
            DoubleArray::class.java,
            IntArray::class.java,
        )
    }.getOrNull()

    private val extrinsicsMethod: Method? = runCatching {
        PXRCapture::class.java.getMethod(
            METHOD_GET_CAMERA_EXTRINSICS,
            DoubleArray::class.java,
            IntArray::class.java,
            DoubleArray::class.java,
            IntArray::class.java,
        )
    }.getOrNull()

    fun buildMetadataBytes(
        capture: PXRCapture?,
        config: AnchorStreamConfig,
        frameWidth: Int,
        frameHeight: Int,
        imageFormat: Int,
        imagePlanes: JSONArray,
        frameTimestampNs: Long,
        headPoseSnapshot: PicoHeadPoseProvider.HeadPoseSnapshot,
    ): ByteArray {
        val metadata = JSONObject()
            .put("schema_version", METADATA_SCHEMA_VERSION)
            .put("device_model", Build.MODEL)
            .put("device_system", Build.DISPLAY)
            .put("frame_timestamp_ns", frameTimestampNs)
            .put("stream_width", config.width)
            .put("stream_height", config.height)
            .put("frame_width", frameWidth)
            .put("frame_height", frameHeight)
            .put("image_format", imageFormat)
            .put("image_format_name", imageFormatName(imageFormat))
            .put("image_plane_count", imagePlanes.length())
            .put("image_planes", imagePlanes)
            .put("render_mode", config.renderMode)
            .put("render_mode_name", renderModeName(config.renderMode))
            .put("output_camera_raw_data", config.outputCameraRawData)
            .put("configured_horizontal_fov_degrees", config.horizontalFovDegrees)
            .put("configured_vertical_fov_degrees", config.verticalFovDegrees)
            .put(
                "output_camera_mode_name",
                if (config.outputCameraRawData) OUTPUT_MODE_RAW else OUTPUT_MODE_RECTIFIED
            )
            .put("selected_camera_index", selectCameraIndex(config.renderMode))
        headPoseSnapshot.appendTo(metadata)

        if (capture == null) {
            metadata
                .put("camera_intrinsics_status", STATUS_CAPTURE_UNAVAILABLE)
                .put("camera_extrinsics_status", STATUS_CAPTURE_UNAVAILABLE)
            return metadata.toString().toByteArray(Charsets.UTF_8)
        }

        val intrinsicsResults = collectIntrinsicsResults(capture, config, frameWidth, frameHeight)
        val intrinsics = selectBestIntrinsics(intrinsicsResults)
        metadata
            .put("camera_intrinsics_status", intrinsics.status)
            .put("camera_intrinsics_probe", intrinsics.probeName)
            .put("camera_intrinsics_width", intrinsics.width)
            .put("camera_intrinsics_height", intrinsics.height)
            .put("camera_intrinsics_horizontal_fov_degrees", intrinsics.horizontalFovDegrees)
            .put("camera_intrinsics_vertical_fov_degrees", intrinsics.verticalFovDegrees)
            .put("camera_intrinsics_value_count", intrinsics.values.size)
            .put(
                "camera_intrinsics_value_order",
                PicoCameraCalibration.INTRINSICS_VALUE_ORDER,
            )
            .put("camera_intrinsics", toJsonArray(intrinsics.values))
            .put("camera_intrinsics_all", intrinsicsResultsToJson(intrinsicsResults))
            .put("camera_intrinsics_probe_count", intrinsicsResults.size)
        annotateIntrinsics(metadata, intrinsics.values)

        val extrinsics = collectExtrinsics(capture)
        metadata
            .put("camera_extrinsics_status", extrinsics.status)
            .put(
                "camera_extrinsics_call_succeeded",
                extrinsics.status == NATIVE_BOOLEAN_SUCCESS,
            )
            .put("camera_extrinsics_primary_count", extrinsics.primaryValues.size)
            .put("camera_extrinsics_primary", toJsonArray(extrinsics.primaryValues))
            .put("camera_extrinsics_secondary_count", extrinsics.secondaryValues.size)
            .put("camera_extrinsics_secondary", toJsonArray(extrinsics.secondaryValues))
        annotateExtrinsics(metadata, "camera_extrinsics_primary", extrinsics.primaryValues)
        annotateExtrinsics(metadata, "camera_extrinsics_secondary", extrinsics.secondaryValues)
        annotateCameraModel(metadata, config, extrinsics)

        return metadata.toString().toByteArray(Charsets.UTF_8)
    }

    private fun annotateCameraModel(metadata: JSONObject, config: AnchorStreamConfig, extrinsics: ExtrinsicsResult) {
        val left = PicoCameraCalibration.cameraToHeadCv(extrinsics.primaryValues)
        val right = PicoCameraCalibration.cameraToHeadCv(extrinsics.secondaryValues)
        val status = when {
            Build.MODEL != PicoCameraCalibration.ULTRA_MODEL -> "unsupported_device"
            config.outputCameraRawData || config.renderMode !in 0..1 -> "unsupported_image_mode"
            extrinsics.status != NATIVE_BOOLEAN_SUCCESS -> "sdk_read_failed"
            left == null || right == null -> "invalid_extrinsics"
            else -> "valid"
        }
        metadata.put("camera_to_head_status", status)
        metadata.put("camera_intrinsics_source", "configured_fov")
        if (!config.outputCameraRawData &&
            kotlin.math.abs(config.horizontalFovDegrees - PicoCameraCalibration.RECTIFIED_HORIZONTAL_FOV_DEGREES) < 0.001 &&
            kotlin.math.abs(config.verticalFovDegrees - PicoCameraCalibration.RECTIFIED_VERTICAL_FOV_DEGREES) < 0.001
        ) {
            metadata.put("camera_intrinsics_source", "pico_4_ultra_rectified_sdk_fov")
        }
        if (status != "valid") return
        metadata
            .put("camera_to_head_convention", PicoCameraCalibration.CAMERA_TO_HEAD_CONVENTION)
            .put("camera_to_head_units", "metres")
            .put("camera_to_head_primary", toJsonArray(left!!))
            .put("camera_to_head_secondary", toJsonArray(right!!))
    }

    private fun collectIntrinsicsResults(
        capture: PXRCapture,
        config: AnchorStreamConfig,
        frameWidth: Int,
        frameHeight: Int,
    ): List<IntrinsicsResult> {
        val method = intrinsicsMethod ?: return listOf(
            IntrinsicsResult(
                status = STATUS_METHOD_MISSING,
                probeName = "method_missing"
            )
        )
        val probes = buildIntrinsicsProbes(config, frameWidth, frameHeight)
        val results = mutableListOf<IntrinsicsResult>()
        for (probe in probes) {
            val valuesBuffer = DoubleArray(INTRINSICS_BUFFER_SIZE) { Double.NaN }
            val valueCountHolder = intArrayOf(valuesBuffer.size)
            val status = invokeInt(
                method,
                capture,
                probe.width,
                probe.height,
                probe.horizontalFovDegrees,
                probe.verticalFovDegrees,
                valuesBuffer,
                valueCountHolder,
            )
            val values = trimBuffer(valuesBuffer, valueCountHolder)
            val result = IntrinsicsResult(
                status = status,
                probeName = probe.name,
                width = probe.width,
                height = probe.height,
                horizontalFovDegrees = probe.horizontalFovDegrees,
                verticalFovDegrees = probe.verticalFovDegrees,
                values = values,
            )
            results += result
        }
        return results.ifEmpty {
            listOf(
                IntrinsicsResult(
                    status = STATUS_INVOCATION_FAILED,
                    probeName = "not_invoked"
                )
            )
        }
    }

    private fun selectBestIntrinsics(results: List<IntrinsicsResult>): IntrinsicsResult {
        return results.firstOrNull { result ->
            result.status == NATIVE_BOOLEAN_SUCCESS &&
                PicoCameraCalibration.isValidIntrinsics(result.values)
        } ?: results.lastOrNull() ?: IntrinsicsResult(
            status = STATUS_INVOCATION_FAILED,
            probeName = "not_invoked",
        )
    }

    private fun collectExtrinsics(capture: PXRCapture): ExtrinsicsResult {
        val method = extrinsicsMethod ?: return ExtrinsicsResult(status = STATUS_METHOD_MISSING)
        val primaryBuffer = DoubleArray(EXTRINSICS_BUFFER_SIZE) { Double.NaN }
        val secondaryBuffer = DoubleArray(EXTRINSICS_BUFFER_SIZE) { Double.NaN }
        val primaryCountHolder = intArrayOf(primaryBuffer.size)
        val secondaryCountHolder = intArrayOf(secondaryBuffer.size)
        val status = invokeInt(
            method,
            capture,
            primaryBuffer,
            primaryCountHolder,
            secondaryBuffer,
            secondaryCountHolder,
        )
        return ExtrinsicsResult(
            status = status,
            primaryValues = trimBuffer(primaryBuffer, primaryCountHolder),
            secondaryValues = trimBuffer(secondaryBuffer, secondaryCountHolder),
        )
    }

    private fun buildIntrinsicsProbes(
        config: AnchorStreamConfig,
        frameWidth: Int,
        frameHeight: Int,
    ): List<IntrinsicsProbe> {
        val horizontalFov = config.horizontalFovDegrees
            .takeIf(PicoCameraCalibration::isValidFov)
            ?: AnchorStreamConfig.DEFAULT_HORIZONTAL_FOV_DEGREES
        val verticalFov = config.verticalFovDegrees
            .takeIf(PicoCameraCalibration::isValidFov)
            ?: AnchorStreamConfig.DEFAULT_VERTICAL_FOV_DEGREES
        return listOf(
            IntrinsicsProbe(
                name = "frame_size_configured_fov",
                width = frameWidth,
                height = frameHeight,
                horizontalFovDegrees = horizontalFov,
                verticalFovDegrees = verticalFov,
            ),
            IntrinsicsProbe(
                name = "stream_size_configured_fov",
                width = config.width,
                height = config.height,
                horizontalFovDegrees = horizontalFov,
                verticalFovDegrees = verticalFov,
            ),
        ).distinctBy { probe ->
            listOf(
                probe.width,
                probe.height,
                probe.horizontalFovDegrees,
                probe.verticalFovDegrees,
            )
        }
    }

    private fun selectCameraIndex(renderMode: Int): Int {
        return when (renderMode) {
            RENDER_MODE_RIGHT -> CAMERA_INDEX_RIGHT
            else -> CAMERA_INDEX_LEFT
        }
    }

    private fun invokeInt(method: Method, target: Any, vararg args: Any): Int {
        return runCatching {
            method.invoke(target, *args) as? Int ?: STATUS_INVOCATION_FAILED
        }.getOrDefault(STATUS_INVOCATION_FAILED)
    }

    private fun trimBuffer(values: DoubleArray, countHolder: IntArray): List<Double> {
        val requestedCount = countHolder.firstOrNull() ?: 0
        val effectiveCount = when {
            requestedCount in 1..values.size -> requestedCount
            else -> {
                val firstNaN = values.indexOfFirst { it.isNaN() }
                when {
                    firstNaN > 0 -> firstNaN
                    firstNaN == 0 -> 0
                    else -> values.size
                }
            }
        }
        return List(effectiveCount) { index -> values[index] }
    }

    private fun toJsonArray(values: List<Double>): JSONArray {
        val jsonArray = JSONArray()
        values.forEach { value ->
            jsonArray.put(if (value.isFinite()) value else JSONObject.NULL)
        }
        return jsonArray
    }

    private fun intrinsicsResultsToJson(results: List<IntrinsicsResult>): JSONArray {
        val jsonArray = JSONArray()
        results.forEach { result ->
            jsonArray.put(
                JSONObject()
                    .put("status", result.status)
                    .put("probe", result.probeName)
                    .put("width", result.width)
                    .put("height", result.height)
                    .put("horizontal_fov_degrees", result.horizontalFovDegrees)
                    .put("vertical_fov_degrees", result.verticalFovDegrees)
                    .put("value_count", result.values.size)
                    .put(
                        "valid",
                        PicoCameraCalibration.isValidIntrinsics(result.values),
                    )
                    .put("values", toJsonArray(result.values))
            )
        }
        return jsonArray
    }

    private fun renderModeName(renderMode: Int): String {
        return when (renderMode) {
            RENDER_MODE_LEFT -> "left"
            RENDER_MODE_RIGHT -> "right"
            RENDER_MODE_3D -> "3d"
            RENDER_MODE_INTERLACE -> "interlace"
            else -> "unknown_$renderMode"
        }
    }

    private fun imageFormatName(format: Int): String {
        return when (format) {
            PixelFormat.RGBA_8888 -> "RGBA_8888"
            ImageFormat.YUV_420_888 -> "YUV_420_888"
            else -> "unknown_$format"
        }
    }

    private fun annotateIntrinsics(metadata: JSONObject, values: List<Double>) {
        val available = PicoCameraCalibration.isValidIntrinsics(values)
        metadata.put("camera_intrinsics_available", available)
        if (!available) {
            metadata.put("camera_intrinsics_error", "invalid_cx_cy_fx_fy")
            return
        }
        metadata
            .put("camera_intrinsics_cx", values[0])
            .put("camera_intrinsics_cy", values[1])
            .put("camera_intrinsics_fx", values[2])
            .put("camera_intrinsics_fy", values[3])
    }

    private fun annotateExtrinsics(
        metadata: JSONObject,
        keyPrefix: String,
        values: List<Double>,
    ) {
        val available = PicoCameraCalibration.isValidExtrinsic(values)
        metadata.put("${keyPrefix}_available", available)
        if (!available) {
            return
        }
        metadata.put("${keyPrefix}_matrix_4x4", toMatrix4x4JsonArray(values))
        metadata.put(
            "${keyPrefix}_translation_row_major",
            toJsonArray(listOf(values[3], values[7], values[11])),
        )
        metadata.put(
            "${keyPrefix}_translation_column_major",
            toJsonArray(listOf(values[12], values[13], values[14])),
        )
    }

    private fun toMatrix4x4JsonArray(values: List<Double>): JSONArray {
        val matrix = JSONArray()
        for (row in 0 until 4) {
            val rowArray = JSONArray()
            for (column in 0 until 4) {
                rowArray.put(values[row * 4 + column])
            }
            matrix.put(rowArray)
        }
        return matrix
    }

    data class IntrinsicsProbe(
        val name: String,
        val width: Int,
        val height: Int,
        val horizontalFovDegrees: Double,
        val verticalFovDegrees: Double,
    )

    data class IntrinsicsResult(
        val status: Int,
        val probeName: String,
        val width: Int = 0,
        val height: Int = 0,
        val horizontalFovDegrees: Double = 0.0,
        val verticalFovDegrees: Double = 0.0,
        val values: List<Double> = emptyList(),
    )

    data class ExtrinsicsResult(
        val status: Int,
        val primaryValues: List<Double> = emptyList(),
        val secondaryValues: List<Double> = emptyList(),
    )

    companion object {
        private const val METHOD_GET_CAMERA_INTRINSICS = "getCameraIntrinsics"
        private const val METHOD_GET_CAMERA_EXTRINSICS = "getCameraExtrinsics"
        // The capturelib JNI methods expose boolean success as int: 1 succeeds.
        private const val NATIVE_BOOLEAN_SUCCESS = 1
        private const val STATUS_METHOD_MISSING = Int.MIN_VALUE
        private const val STATUS_INVOCATION_FAILED = Int.MIN_VALUE + 1
        private const val STATUS_CAPTURE_UNAVAILABLE = Int.MIN_VALUE + 2
        private const val METADATA_SCHEMA_VERSION = 1
        private const val INTRINSICS_BUFFER_SIZE = 64
        private const val EXTRINSICS_BUFFER_SIZE = 64
        private const val CAMERA_INDEX_LEFT = 0
        private const val CAMERA_INDEX_RIGHT = 1
        private const val RENDER_MODE_LEFT = 0
        private const val RENDER_MODE_RIGHT = 1
        private const val RENDER_MODE_3D = 2
        private const val RENDER_MODE_INTERLACE = 3
        private const val OUTPUT_MODE_RAW = "raw_fisheye"
        private const val OUTPUT_MODE_RECTIFIED = "rectified"
    }
}
