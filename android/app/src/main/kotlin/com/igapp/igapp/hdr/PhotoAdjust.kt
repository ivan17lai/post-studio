package com.igapp.igapp.hdr

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.os.Build

/**
 * Per-photo "deep adjust" helpers shared by the live preview ([HdrImageView])
 * and the exporter ([NativePageRenderer]).
 *
 * The linear adjustments (brightness/contrast/saturation/white balance) ride a
 * 4x5 colour matrix computed on the Dart side and applied here as a
 * [ColorMatrixColorFilter]. Highlights/shadows are a luminance-weighted tone
 * curve that a colour matrix cannot express, so they are applied as a per-pixel
 * pass ([applyToneCurve]) — kept off the matrix path on purpose.
 */
object PhotoAdjust {
    /** Strength of the highlights/shadows tone curve at full slider deflection. */
    private const val TONE_GAIN = 0.6f

    /** Builds a [ColorMatrixColorFilter] from a 20-float payload, or null. */
    fun colorMatrixFilter(raw: Any?): ColorMatrixColorFilter? {
        val list = raw as? List<*> ?: return null
        if (list.size != 20) {
            return null
        }
        val values = FloatArray(20) { i -> (list[i] as? Number)?.toFloat() ?: 0f }
        return ColorMatrixColorFilter(ColorMatrix(values))
    }

    /**
     * Applies the highlights/shadows tone curve to [src], returning a new bitmap
     * (the original's gain map is carried over so HDR survives). Returns [src]
     * unchanged when both controls are neutral.
     *
     * highlights > 0 brightens bright tones; shadows > 0 lifts dark tones (and
     * negative values do the opposite), weighted by per-pixel luminance.
     */
    fun applyToneCurve(src: Bitmap, highlights: Float, shadows: Float): Bitmap {
        if (highlights == 0f && shadows == 0f) {
            return src
        }
        val factorLut = FloatArray(256) { i ->
            val l = i / 255f
            val highWeight = l * l
            val lowWeight = (1f - l) * (1f - l)
            (1f + highlights * TONE_GAIN * highWeight + shadows * TONE_GAIN * lowWeight)
                .coerceIn(0f, 4f)
        }

        val argb =
            if (src.config == Bitmap.Config.ARGB_8888) src else src.copy(Bitmap.Config.ARGB_8888, false)
        val width = argb.width
        val height = argb.height
        val pixels = IntArray(width * height)
        argb.getPixels(pixels, 0, width, 0, 0, width, height)
        for (i in pixels.indices) {
            val c = pixels[i]
            val r = Color.red(c)
            val g = Color.green(c)
            val b = Color.blue(c)
            val luma = (0.2126f * r + 0.7152f * g + 0.0722f * b).toInt().coerceIn(0, 255)
            val f = factorLut[luma]
            pixels[i] = Color.argb(
                Color.alpha(c),
                (r * f).toInt().coerceIn(0, 255),
                (g * f).toInt().coerceIn(0, 255),
                (b * f).toInt().coerceIn(0, 255),
            )
        }
        if (argb !== src) {
            argb.recycle()
        }
        val out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        out.setPixels(pixels, 0, width, 0, 0, width, height)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && src.hasGainmap()) {
            out.gainmap = src.gainmap
        }
        return out
    }
}
