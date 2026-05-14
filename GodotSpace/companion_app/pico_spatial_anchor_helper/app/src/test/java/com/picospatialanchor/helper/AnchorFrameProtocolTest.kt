package com.picospatialanchor.helper

import org.junit.Assert.*
import org.junit.Test

class AnchorFrameProtocolTest {
    @Test
    fun frameHeaderConstantsMatchSpatialAnchorProtocol() {
        assertEquals(0x50534132, AnchorFrameProtocol.FRAME_MAGIC_PSA2)
        assertEquals(0x50414131, AnchorFrameProtocol.ACK_MAGIC_PAA1)
        assertEquals(32, AnchorFrameProtocol.FRAME_HEADER_SIZE)
        assertEquals(8, AnchorFrameProtocol.ACK_HEADER_SIZE)
    }
}
