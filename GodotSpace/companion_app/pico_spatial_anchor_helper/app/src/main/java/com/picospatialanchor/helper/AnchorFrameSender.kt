package com.picospatialanchor.helper

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class AnchorFrameSender(
    private val host: String,
    private val port: Int,
    private val onStatusChanged: (String) -> Unit,
) {

    private val packetQueue = ArrayBlockingQueue<FramePacket>(1)
    private val pendingFrameSendNs = ConcurrentHashMap<Int, Long>()

    @Volatile
    private var running = false

    @Volatile
    private var socket: Socket? = null

    private var worker: Thread? = null

    fun start() {
        if (running) {
            return
        }
        running = true
        worker = Thread(::runLoop, "anchor-frame-sender").apply { start() }
    }

    fun offer(
        frameId: Int,
        timestampNs: Long,
        width: Int,
        height: Int,
        metadataBytes: ByteArray,
        jpegBytes: ByteArray,
    ) {
        if (!running) {
            return
        }
        val payload = ByteBuffer
            .allocate(AnchorFrameProtocol.FRAME_HEADER_SIZE + metadataBytes.size + jpegBytes.size)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(AnchorFrameProtocol.FRAME_MAGIC_PSA2)
            .putInt(frameId)
            .putLong(timestampNs)
            .putInt(width)
            .putInt(height)
            .putInt(metadataBytes.size)
            .putInt(jpegBytes.size)
            .put(metadataBytes)
            .put(jpegBytes)
            .array()
        val packet = FramePacket(frameId = frameId, payload = payload)

        packetQueue.poll()
        packetQueue.offer(packet)
    }

    fun stop() {
        running = false
        worker?.interrupt()
        packetQueue.clear()
        pendingFrameSendNs.clear()
        closeSocket()
    }

    private fun runLoop() {
        while (running) {
            try {
                onStatusChanged("正在连接 $host:$port")
                val client = Socket()
                client.keepAlive = true
                client.tcpNoDelay = true
                client.soTimeout = ACK_SOCKET_TIMEOUT_MS
                client.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
                socket = client

                BufferedInputStream(client.getInputStream()).use { input ->
                    BufferedOutputStream(client.getOutputStream()).use { output ->
                        val ackThread = Thread(
                            { readAckLoop(input) },
                            "anchor-frame-sender-ack",
                        ).apply { start() }

                        onStatusChanged("已连接 $host:$port，等待发送画面")
                        try {
                            while (running) {
                                val packet = packetQueue.poll(1, TimeUnit.SECONDS) ?: continue
                                output.write(packet.payload)
                                output.flush()
                                pendingFrameSendNs[packet.frameId] = System.nanoTime()
                                trimPendingFrames(packet.frameId)
                            }
                        } finally {
                            ackThread.interrupt()
                            runCatching { ackThread.join(200) }
                        }
                    }
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (_: IOException) {
                if (running) {
                    onStatusChanged("接收端不可用，2 秒后重试")
                    sleepQuietly(RECONNECT_DELAY_MS)
                }
            } finally {
                closeSocket()
            }
        }
    }

    private fun readAckLoop(input: BufferedInputStream) {
        val ackHeader = ByteArray(AnchorFrameProtocol.ACK_HEADER_SIZE)
        while (running) {
            try {
                readFully(input, ackHeader, AnchorFrameProtocol.ACK_HEADER_SIZE)
                val magic = readIntBe(ackHeader, 0)
                if (magic != AnchorFrameProtocol.ACK_MAGIC_PAA1) {
                    continue
                }
                val frameId = readIntBe(ackHeader, 4)
                pendingFrameSendNs.remove(frameId)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: EOFException) {
                break
            } catch (_: IOException) {
                break
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }
    }

    @Throws(IOException::class, InterruptedException::class)
    private fun readFully(input: BufferedInputStream, buffer: ByteArray, size: Int) {
        var offset = 0
        while (offset < size) {
            if (Thread.currentThread().isInterrupted) {
                throw InterruptedException("ack thread interrupted")
            }
            val read = input.read(buffer, offset, size - offset)
            if (read < 0) {
                throw EOFException("socket closed")
            }
            offset += read
        }
    }

    private fun trimPendingFrames(latestFrameId: Int) {
        if (pendingFrameSendNs.size <= MAX_PENDING_ACK_FRAMES) {
            return
        }
        val threshold = latestFrameId - PENDING_FRAME_RETENTION
        val iterator = pendingFrameSendNs.keys.iterator()
        while (iterator.hasNext()) {
            val key = iterator.next()
            if (key < threshold) {
                iterator.remove()
            }
        }
    }

    private fun readIntBe(buffer: ByteArray, offset: Int): Int {
        return ((buffer[offset].toInt() and 0xFF) shl 24) or
            ((buffer[offset + 1].toInt() and 0xFF) shl 16) or
            ((buffer[offset + 2].toInt() and 0xFF) shl 8) or
            (buffer[offset + 3].toInt() and 0xFF)
    }

    private fun closeSocket() {
        try {
            socket?.close()
        } catch (_: IOException) {
        } finally {
            socket = null
        }
    }

    private fun sleepQuietly(delayMs: Long) {
        try {
            Thread.sleep(delayMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    data class FramePacket(
        val frameId: Int,
        val payload: ByteArray,
    )

    companion object {
        private const val CONNECT_TIMEOUT_MS = 2_000
        private const val RECONNECT_DELAY_MS = 2_000L
        private const val ACK_SOCKET_TIMEOUT_MS = 1_000
        private const val MAX_PENDING_ACK_FRAMES = 1_024
        private const val PENDING_FRAME_RETENTION = 600
    }
}
