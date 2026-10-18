package com.picospatialanchor.helper

import android.graphics.PixelFormat
import android.os.Build
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.pxr.capturelib.PXRCapture
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Reads calibration only: no camera images, foreground service, or network sender. */
@RunWith(AndroidJUnit4::class)
class PicoCameraModelInstrumentedTest {
    @Test
    fun deviceCalibrationReachesProductionMetadata() {
        assumeTrue(Build.MODEL == "A9410")
        val capture = PXRCapture()
        val collector = PicoCaptureMetadataCollector()
        val config = AnchorStreamConfig(host = "127.0.0.1", port = AnchorStreamConfig.DEFAULT_PORT)
        fun read(current: AnchorStreamConfig): JSONObject = JSONObject(
            String(
                collector.buildMetadataBytes(
                    capture = capture,
                    config = current,
                    frameWidth = current.width,
                    frameHeight = current.height,
                    imageFormat = PixelFormat.RGBA_8888,
                    imagePlanes = JSONArray(),
                    frameTimestampNs = SystemClock.elapsedRealtimeNanos(),
                    headPoseSnapshot = PicoHeadPoseProvider.HeadPoseSnapshot(
                        available = false,
                        bindState = "diagnostic_not_requested",
                    ),
                ),
                Charsets.UTF_8,
            ),
        )

        val left = read(config)
        assertEquals("valid", left.getString("camera_to_head_status"))
        assertEquals(1, left.getInt("camera_extrinsics_status"))
        assertEquals(1, left.getInt("camera_intrinsics_status"))
        assertEquals("pico_4_ultra_rectified_sdk_fov", left.getString("camera_intrinsics_source"))
        assertEquals(76.35, left.getDouble("camera_intrinsics_horizontal_fov_degrees"), 0.001)
        assertEquals(61.05, left.getDouble("camera_intrinsics_vertical_fov_degrees"), 0.001)
        assertEquals(0, left.getInt("selected_camera_index"))
        assertTrue(left.getJSONArray("camera_to_head_primary").getDouble(3) < 0.0)
        assertTrue(left.getJSONArray("camera_to_head_secondary").getDouble(3) > 0.0)
        assertTrue(left.getJSONArray("camera_to_head_primary").getDouble(11) < 0.0)
        val right = read(config.copy(renderMode = 1))
        assertEquals("valid", right.getString("camera_to_head_status"))
        assertEquals(1, right.getInt("selected_camera_index"))
        val raw = read(config.copy(outputCameraRawData = true))
        assertEquals("unsupported_image_mode", raw.getString("camera_to_head_status"))
        assertFalse(raw.has("camera_to_head_primary"))

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.openFileOutput("pico_camera_model_diagnostic.json", 0).use {
            it.write(left.toString(2).toByteArray(Charsets.UTF_8))
        }
        context.openFileOutput("pico_camera_model_right_diagnostic.json", 0).use {
            it.write(right.toString(2).toByteArray(Charsets.UTF_8))
        }
    }
}
