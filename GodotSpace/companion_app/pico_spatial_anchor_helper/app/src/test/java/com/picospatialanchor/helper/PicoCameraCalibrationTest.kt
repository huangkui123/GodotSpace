package com.picospatialanchor.helper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PicoCameraCalibrationTest {

    @Test
    fun validatesCxCyFxFyOrdering() {
        assertFalse(
            PicoCameraCalibration.isValidIntrinsics(
                listOf(-0.5, -0.5, 0.0, 0.0),
            ),
        )
        assertTrue(
            PicoCameraCalibration.isValidIntrinsics(
                listOf(479.5, 359.5, 480.0, 480.0),
            ),
        )
    }

    @Test
    fun validatesFovRange() {
        assertFalse(PicoCameraCalibration.isValidFov(0.0))
        assertFalse(PicoCameraCalibration.isValidFov(180.0))
        assertTrue(PicoCameraCalibration.isValidFov(90.0))
    }

    @Test
    fun acceptsLoggedRigidExtrinsicAndRejectsInvalidLastRow() {
        val loggedExtrinsic = listOf(
            -0.00041123088404249,
            -0.999970852743284,
            -0.00762394602750735,
            -0.0207797543771739,
            -0.999993066328062,
            0.00038299907960075,
            0.00370413383992514,
            0.0829515156686094,
            -0.00370110591027374,
            0.00762541641980033,
            -0.999964076774494,
            -0.0171808917763377,
            0.0,
            0.0,
            0.0,
            1.0,
        )
        assertTrue(PicoCameraCalibration.isValidExtrinsic(loggedExtrinsic))
        val headFromCamera = PicoCameraCalibration.cameraToHeadCv(loggedExtrinsic)!!
        assertEquals(-0.0323815156686094, headFromCamera[3], 1e-9)
        assertEquals(-0.0020397543771739, headFromCamera[7], 1e-9)
        assertEquals(-0.0691208917763377, headFromCamera[11], 1e-9)
        // Optical +Z points forward (-Z) in the OpenXR head frame.
        assertTrue(headFromCamera[0] > 0.99)
        assertTrue(headFromCamera[5] < -0.99)
        assertTrue(headFromCamera[10] < -0.99)
        val right = loggedExtrinsic.toMutableList().also {
            it[3] = -0.02080614973530011
            it[7] = 0.018765735529823607
            it[11] = -0.01741845179372815
        }
        assertEquals(0.0318042644701764, PicoCameraCalibration.cameraToHeadCv(right)!![3], 1e-9)
        assertFalse(
            PicoCameraCalibration.isValidExtrinsic(
                loggedExtrinsic.toMutableList().also { it[15] = 0.0 },
            ),
        )
    }

    @Test
    fun rejectsShearNonfiniteAndWrongUnits() {
        val identity = listOf(1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0)
        assertFalse(PicoCameraCalibration.isValidExtrinsic(identity.toMutableList().also { it[1] = 0.1 }))
        assertFalse(PicoCameraCalibration.isValidExtrinsic(identity.toMutableList().also { it[3] = Double.NaN }))
        assertNull(PicoCameraCalibration.cameraToHeadCv(identity.toMutableList().also { it[3] = 20.0 }))
    }
}
