package com.picospatialanchor.helper

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AnchorInstrumentedTest {
    @Test
    fun appPackageNameMatchesSpatialAnchorHelper() {
        val appContext = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals("com.picospatialanchor.helper", appContext.packageName)
    }
}
