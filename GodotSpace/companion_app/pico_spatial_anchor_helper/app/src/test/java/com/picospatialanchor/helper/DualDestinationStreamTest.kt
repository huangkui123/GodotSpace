package com.picospatialanchor.helper

import java.io.DataInputStream
import java.net.ServerSocket
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class DualDestinationStreamTest {
    @Test
    fun unavailableServerDoesNotBlockSkyFrames() {
        ServerSocket(0).use { receiver ->
            receiver.soTimeout = 4000
            // Reserve a second port without accepting: its sender must never
            // block the independent Sky queue or capture caller.
            ServerSocket(0).use { unavailable ->
                val sky = AnchorFrameSender("127.0.0.1", receiver.localPort) { }
                val server = AnchorFrameSender("127.0.0.1", unavailable.localPort) { }
                val metadata = "{\"source\":\"fixture\"}".toByteArray()
                val jpeg = byteArrayOf(1, 2, 3, 4)
                try {
                    sky.start()
                    server.start()
                    repeat(100) { id ->
                        sky.offer(id, 123L, 960, 720, metadata, jpeg)
                        server.offer(id, 123L, 960, 720, metadata, jpeg)
                    }
                    receiver.accept().use { socket ->
                        socket.soTimeout = 4000
                        val input = DataInputStream(socket.getInputStream())
                        assertEquals(AnchorFrameProtocol.FRAME_MAGIC_PSA2, input.readInt())
                        input.readInt()
                        assertEquals(123L, input.readLong())
                        assertEquals(960, input.readInt())
                        assertEquals(720, input.readInt())
                        val metadataSize = input.readInt()
                        val jpegSize = input.readInt()
                        val receivedMetadata = ByteArray(metadataSize).also { input.readFully(it) }
                        val receivedJpeg = ByteArray(jpegSize).also { input.readFully(it) }
                        assertArrayEquals(metadata, receivedMetadata)
                        assertArrayEquals(jpeg, receivedJpeg)
                    }
                } finally {
                    sky.stop()
                    server.stop()
                }
            }
        }
    }
}
