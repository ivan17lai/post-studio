package com.igapp.igapp.hdr

import android.app.Activity
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import java.io.File
import java.io.FileInputStream

/**
 * Device capability checks and Ultra HDR (JPEG gain map) helpers shared by the
 * import pipeline, the page renderer and the HDR preview platform view.
 */
object UltraHdrSupport {
    /** Android 14+ exposes the Gainmap APIs used everywhere in this module. */
    val supportsGainmap: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

    fun capabilities(activity: Activity): Map<String, Any> {
        val windowHdr =
            supportsGainmap &&
                activity.window.colorMode == ActivityInfo.COLOR_MODE_HDR
        return mapOf(
            "apiLevel" to Build.VERSION.SDK_INT,
            "supportsGainmap" to supportsGainmap,
            "windowColorModeHdr" to windowHdr,
        )
    }

    /** Switches the window between HDR and default color mode. No-op below API 34. */
    fun setWindowHdrColorMode(activity: Activity, enabled: Boolean): Boolean {
        if (!supportsGainmap) {
            return false
        }
        activity.window.colorMode =
            if (enabled) ActivityInfo.COLOR_MODE_HDR else ActivityInfo.COLOR_MODE_DEFAULT
        return true
    }

    /**
     * Cheap Ultra HDR detection: scans the JPEG header segments (everything
     * before the first scan) for the `hdrgm` XMP namespace that every Ultra HDR
     * primary image carries. Avoids a full bitmap decode at import time.
     */
    fun fileLooksUltraHdr(file: File): Boolean {
        if (!file.exists()) {
            return false
        }
        val headerLimit = 256 * 1024
        val buffer = ByteArray(minOf(headerLimit.toLong(), file.length()).toInt())
        FileInputStream(file).use { input ->
            var read = 0
            while (read < buffer.size) {
                val r = input.read(buffer, read, buffer.size - read)
                if (r <= 0) {
                    break
                }
                read += r
            }
            if (read < 4 || buffer[0] != 0xFF.toByte() || buffer[1] != 0xD8.toByte()) {
                return false
            }
            val scanEnd = indexOfStartOfScan(buffer, read)
            return indexOfAscii(buffer, "hdrgm", scanEnd) >= 0
        }
    }

    /**
     * Inspects an image file: dimensions plus whether it is an Ultra HDR JPEG
     * the current device can actually use. Below API 34 the device cannot read
     * gain maps, so files are reported as SDR there.
     */
    fun inspectImage(path: String): Map<String, Any> {
        val file = File(path)
        val bounds = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
            BitmapFactory.decodeFile(path, this)
        }
        val isUltraHdr = supportsGainmap && fileLooksUltraHdr(file)
        return mapOf(
            "exists" to file.exists(),
            "width" to bounds.outWidth,
            "height" to bounds.outHeight,
            "isUltraHdr" to isUltraHdr,
        )
    }

    /**
     * Decodes a bitmap keeping its gain map when the device supports it.
     * [maxSide] proportionally downsizes the result (gain map included) — used
     * by the preview platform view so huge photos do not stall the UI.
     */
    fun decodeWithGainmap(path: String, maxSide: Int = 0): Bitmap? {
        val file = File(path)
        if (!file.exists()) {
            return null
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                val source = ImageDecoder.createSource(file)
                return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    decoder.isMutableRequired = true
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    if (maxSide > 0) {
                        val longest = maxOf(info.size.width, info.size.height)
                        if (longest > maxSide) {
                            val scale = maxSide.toFloat() / longest
                            decoder.setTargetSize(
                                (info.size.width * scale).toInt().coerceAtLeast(1),
                                (info.size.height * scale).toInt().coerceAtLeast(1),
                            )
                        }
                    }
                }
            } catch (_: Exception) {
                // Fall through to the legacy decoder below.
            }
        }

        val options = BitmapFactory.Options()
        if (maxSide > 0) {
            val bounds = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
                BitmapFactory.decodeFile(path, this)
            }
            var sampleSize = 1
            var longest = maxOf(bounds.outWidth, bounds.outHeight)
            while (longest > maxSide * 2) {
                sampleSize *= 2
                longest /= 2
            }
            options.inSampleSize = sampleSize
        }
        return BitmapFactory.decodeFile(path, options)
    }

    /**
     * Applies a per-image HDR brightness to an already-decoded bitmap for the
     * live preview, mirroring what the export renderer bakes into the output
     * gain map:
     *  - HDR source: scales its existing gain map ([CanonicalGainmapSpace.scaledGainmap]).
     *  - SDR source with brightness > 1: synthesizes a gain map at that peak.
     *  - brightness == 1 (or SDR ≤ 1): returns the bitmap untouched.
     *
     * Mutates and returns [bitmap]. No-op below API 34.
     */
    fun applyPreviewBrightness(bitmap: Bitmap, brightness: Float): Bitmap {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return bitmap
        }
        val safe = brightness.coerceIn(0f, 8f)
        if (bitmap.hasGainmap()) {
            if (safe == 1f) {
                return bitmap
            }
            val gainmap = bitmap.gainmap ?: return bitmap
            bitmap.gainmap = CanonicalGainmapSpace.scaledGainmap(gainmap, safe)
        } else if (safe > 1f) {
            val space = CanonicalGainmapSpace.forSources(emptyList(), safe)
            val contents =
                space.synthesizeFromSdr(
                    bitmap,
                    downscale = CanonicalGainmapSpace.SYNTHESIS_DOWNSCALE,
                    maxGain = safe,
                )
            bitmap.gainmap =
                space.toGainmap(
                    contents,
                    safe,
                    1f,
                    CanonicalGainmapSpace.defaultEpsilon(),
                    CanonicalGainmapSpace.defaultEpsilon(),
                )
        }
        return bitmap
    }

    private fun indexOfStartOfScan(buffer: ByteArray, length: Int): Int {
        var i = 2
        while (i + 3 < length) {
            if (buffer[i] != 0xFF.toByte()) {
                i++
                continue
            }
            val marker = buffer[i + 1].toInt() and 0xFF
            if (marker == 0xDA) {
                return i
            }
            // Standalone markers without a length payload.
            if (marker == 0xD8 || marker == 0x01 || (marker in 0xD0..0xD7)) {
                i += 2
                continue
            }
            val segmentLength =
                ((buffer[i + 2].toInt() and 0xFF) shl 8) or (buffer[i + 3].toInt() and 0xFF)
            if (segmentLength < 2) {
                return length
            }
            i += 2 + segmentLength
        }
        return length
    }

    private fun indexOfAscii(buffer: ByteArray, needle: String, limit: Int): Int {
        val bytes = needle.toByteArray(Charsets.US_ASCII)
        val end = minOf(limit, buffer.size) - bytes.size
        outer@ for (i in 0..end) {
            for (j in bytes.indices) {
                if (buffer[i + j] != bytes[j]) {
                    continue@outer
                }
            }
            return i
        }
        return -1
    }
}
