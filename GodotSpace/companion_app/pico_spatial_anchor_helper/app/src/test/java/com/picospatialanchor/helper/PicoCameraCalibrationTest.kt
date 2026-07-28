package com.picospatialanchor.helper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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
        assertFalse(
            PicoCameraCalibration.isValidExtrinsic(
                loggedExtrinsic.toMutableList().also { it[15] = 0.0 },
            ),
        )
    }
}
