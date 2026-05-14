package com.picospatialanchor.helper

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import java.io.ByteArrayOutputStream
import java.nio.ByteOrder

fun Image.toJpeg(quality: Int): ByteArray {
    return when (format) {
        ImageFormat.YUV_420_888 -> yuv420888ToJpeg(this, quality)
        PixelFormat.RGBA_8888 -> rgba8888ToJpeg(this, quality)
        else -> throw IllegalArgumentException("Unsupported preview image format: $format")
    }
}

private fun yuv420888ToJpeg(image: Image, quality: Int): ByteArray {
    val scratch = YuvJpegScratch.ensure(image.width, image.height)
    yuv420888ToNv21(image, scratch.nv21)
    val stream = scratch.stream
    stream.reset()
    val compressed = YuvImage(scratch.nv21, ImageFormat.NV21, image.width, image.height, null)
        .compressToJpeg(Rect(0, 0, image.width, image.height), quality, stream)

    check(compressed) { "Failed to encode preview frame as JPEG" }
    return stream.toByteArray()
}

private fun rgba8888ToJpeg(image: Image, quality: Int): ByteArray {
    val plane = image.planes.firstOrNull()
        ?: throw IllegalArgumentException("RGBA image has no planes")
    require(plane.pixelStride == 4) {
        "Unsupported RGBA pixelStride: ${plane.pixelStride}"
    }

    val width = image.width
    val height = image.height
    val rowStride = plane.rowStride
    val pixelStride = plane.pixelStride
    val buffer = plane.buffer.duplicate()
    val scratch = RgbaJpegScratch.ensure(width, height, rowStride)
    val pixels = scratch.pixels
    val pixelCount = width * height

    if (rowStride == width * pixelStride) {
        buffer.position(0)
        val rgbaInts = scratch.rgbaInts
        buffer
            .order(ByteOrder.LITTLE_ENDIAN)
            .asIntBuffer()
            .get(rgbaInts, 0, pixelCount)
        for (index in 0 until pixelCount) {
            pixels[index] = rgbaLittleEndianIntToArgb(rgbaInts[index])
        }
    } else {
        val rowBytes = scratch.rowBytes
        for (row in 0 until height) {
            val rowOffset = row * rowStride
            buffer.position(rowOffset)
            buffer.get(rowBytes, 0, rowStride)
            var sourceOffset = 0
            val pixelRowOffset = row * width
            for (column in 0 until width) {
                val r = rowBytes[sourceOffset].toInt() and 0xFF
                val g = rowBytes[sourceOffset + 1].toInt() and 0xFF
                val b = rowBytes[sourceOffset + 2].toInt() and 0xFF
                val a = rowBytes[sourceOffset + 3].toInt() and 0xFF
                pixels[pixelRowOffset + column] = (a shl 24) or (r shl 16) or (g shl 8) or b
                sourceOffset += pixelStride
            }
        }
    }

    val bitmap = scratch.bitmap
    bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
    val stream = scratch.stream
    stream.reset()
    check(bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)) {
        "Failed to encode RGBA frame as JPEG"
    }
    return stream.toByteArray()
}

private fun rgbaLittleEndianIntToArgb(value: Int): Int {
    return (value and -0x1000000) or
        ((value and 0x000000FF) shl 16) or
        (value and 0x0000FF00) or
        ((value ushr 16) and 0x000000FF)
}

private fun yuv420888ToNv21(image: Image, output: ByteArray) {
    val width = image.width
    val height = image.height

    val yPlane = image.planes[0]
    val uPlane = image.planes[1]
    val vPlane = image.planes[2]

    val yBuffer = yPlane.buffer.duplicate()
    val uBuffer = uPlane.buffer.duplicate()
    val vBuffer = vPlane.buffer.duplicate()

    var outputOffset = 0

    for (row in 0 until height) {
        val rowOffset = row * yPlane.rowStride
        if (yPlane.pixelStride == 1) {
            yBuffer.position(rowOffset)
            yBuffer.get(output, outputOffset, width)
            outputOffset += width
        } else {
            for (column in 0 until width) {
                output[outputOffset++] = yBuffer.get(rowOffset + column * yPlane.pixelStride)
            }
        }
    }

    val chromaHeight = height / 2
    val chromaWidth = width / 2
    for (row in 0 until chromaHeight) {
        val uRowOffset = row * uPlane.rowStride
        val vRowOffset = row * vPlane.rowStride
        for (column in 0 until chromaWidth) {
            output[outputOffset++] = vBuffer.get(vRowOffset + column * vPlane.pixelStride)
            output[outputOffset++] = uBuffer.get(uRowOffset + column * uPlane.pixelStride)
        }
    }

}

private object RgbaJpegScratch {
    private var width = 0
    private var height = 0
    private var bitmap: Bitmap? = null
    private var pixels: IntArray = IntArray(0)
    private var rgbaInts: IntArray = IntArray(0)
    private var rowBytes: ByteArray = ByteArray(0)
    private val stream = ByteArrayOutputStream(512 * 1024)

    fun ensure(targetWidth: Int, targetHeight: Int, rowStride: Int): Scratch {
        val needsResize = bitmap == null || width != targetWidth || height != targetHeight
        if (needsResize) {
            bitmap?.recycle()
            width = targetWidth
            height = targetHeight
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            pixels = IntArray(width * height)
            rgbaInts = IntArray(width * height)
        }
        if (rowBytes.size < rowStride) {
            rowBytes = ByteArray(rowStride)
        }
        return Scratch(
            bitmap = checkNotNull(bitmap),
            pixels = pixels,
            rgbaInts = rgbaInts,
            rowBytes = rowBytes,
            stream = stream,
        )
    }

    data class Scratch(
        val bitmap: Bitmap,
        val pixels: IntArray,
        val rgbaInts: IntArray,
        val rowBytes: ByteArray,
        val stream: ByteArrayOutputStream,
    )
}

private object YuvJpegScratch {
    private var width = 0
    private var height = 0
    private var nv21 = ByteArray(0)
    private val stream = ByteArrayOutputStream(512 * 1024)

    fun ensure(targetWidth: Int, targetHeight: Int): Scratch {
        if (width != targetWidth || height != targetHeight || nv21.isEmpty()) {
            width = targetWidth
            height = targetHeight
            nv21 = ByteArray(width * height * 3 / 2)
        }
        return Scratch(
            nv21 = nv21,
            stream = stream,
        )
    }

    data class Scratch(
        val nv21: ByteArray,
        val stream: ByteArrayOutputStream,
    )
}
