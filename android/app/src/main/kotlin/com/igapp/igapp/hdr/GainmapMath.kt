package com.igapp.igapp.hdr

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Gainmap
import android.graphics.Paint
import android.os.Build
import androidx.annotation.RequiresApi
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Canonical gain map space used when compositing multiple Ultra HDR sources.
 *
 * Different source images encode their gain maps with their own
 * ratioMin/ratioMax/gamma. Before drawing them onto a shared output gain map,
 * every source is re-encoded into this canonical space so all pixel values mean
 * the same thing:
 *
 *   gamma = 1.0, ratioMin = [canonMin] (<= 1), ratioMax = [canonMax]
 *   stored pixel p in [0, 255]  =>  log2(gain) = lerp(log2(canonMin), log2(canonMax), p / 255)
 *
 * [neutralValue] is the stored value for gain == 1.0 and is used to fill every
 * SDR region (page background, SDR images, text), so SDR content keeps its
 * exact appearance inside an HDR export.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class CanonicalGainmapSpace private constructor(
    val canonMin: Float,
    val canonMax: Float,
) {
    private val logMin = log2(canonMin)
    private val logMax = log2(canonMax)

    val neutralValue: Int = encodeLog2(0f)
    val neutralColor: Int = Color.rgb(neutralValue, neutralValue, neutralValue)

    fun encodeLog2(logGain: Float): Int {
        if (logMax <= logMin) {
            return 0
        }
        val t = (logGain - logMin) / (logMax - logMin)
        return (t * 255f).roundToInt().coerceIn(0, 255)
    }

    /** 256-entry LUT translating one source channel's stored values into this space. */
    fun lutFor(srcMin: Float, srcMax: Float, srcGamma: Float): IntArray {
        val srcLogMin = log2(max(srcMin, MIN_RATIO))
        val srcLogMax = log2(max(srcMax, MIN_RATIO))
        val gamma = if (srcGamma > 0f) srcGamma else 1f
        return IntArray(256) { p ->
            val t = (p / 255f).pow(gamma)
            encodeLog2(srcLogMin + t * (srcLogMax - srcLogMin))
        }
    }

    /**
     * Re-encodes a source gain map bitmap into this canonical space.
     * Handles single-channel (ALPHA_8) and RGB gain maps, including sources
     * whose channels carry different parameters.
     */
    fun remapContents(
        contents: Bitmap,
        ratioMin: FloatArray,
        ratioMax: FloatArray,
        gamma: FloatArray,
    ): Bitmap {
        val argb = ensureArgb(contents)
        val width = argb.width
        val height = argb.height
        val lutR = lutFor(ratioMin[0], ratioMax[0], gamma[0])
        val lutG = lutFor(ratioMin[1], ratioMax[1], gamma[1])
        val lutB = lutFor(ratioMin[2], ratioMax[2], gamma[2])
        val pixels = IntArray(width * height)
        argb.getPixels(pixels, 0, width, 0, 0, width, height)
        for (i in pixels.indices) {
            val c = pixels[i]
            pixels[i] = Color.rgb(
                lutR[Color.red(c)],
                lutG[Color.green(c)],
                lutB[Color.blue(c)],
            )
        }
        if (argb !== contents) {
            argb.recycle()
        }
        val out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        out.setPixels(pixels, 0, width, 0, 0, width, height)
        return out
    }

    /**
     * Synthesizes a canonical-space gain map for an SDR source via a simple
     * inverse tone mapping curve: highlights above [SYNTHESIS_LUMA_START]
     * luminance ramp smoothly up to [SYNTHESIS_MAX_GAIN] at pure white.
     */
    fun synthesizeFromSdr(base: Bitmap, downscale: Int = SYNTHESIS_DOWNSCALE): Bitmap {
        val width = max(1, base.width / downscale)
        val height = max(1, base.height / downscale)
        val small = Bitmap.createScaledBitmap(base, width, height, true)
        val pixels = IntArray(width * height)
        small.getPixels(pixels, 0, width, 0, 0, width, height)
        if (small !== base) {
            small.recycle()
        }
        val maxLog = log2(SYNTHESIS_MAX_GAIN)
        val lumaLut = IntArray(256)
        for (v in 0..255) {
            lumaLut[v] = encodeLog2(maxLog * smoothstep(SYNTHESIS_LUMA_START, 1f, v / 255f))
        }
        for (i in pixels.indices) {
            val c = pixels[i]
            val luma =
                (0.2126f * Color.red(c) + 0.7152f * Color.green(c) + 0.0722f * Color.blue(c))
                    .roundToInt()
                    .coerceIn(0, 255)
            val q = lumaLut[luma]
            pixels[i] = Color.rgb(q, q, q)
        }
        val out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        out.setPixels(pixels, 0, width, 0, 0, width, height)
        return out
    }

    /** Wraps canonical-space contents into a [Gainmap] with matching parameters. */
    fun toGainmap(contents: Bitmap): Gainmap {
        return Gainmap(contents).apply {
            setRatioMin(canonMin, canonMin, canonMin)
            setRatioMax(canonMax, canonMax, canonMax)
            setGamma(1f, 1f, 1f)
            setEpsilonSdr(DEFAULT_EPSILON, DEFAULT_EPSILON, DEFAULT_EPSILON)
            setEpsilonHdr(DEFAULT_EPSILON, DEFAULT_EPSILON, DEFAULT_EPSILON)
            displayRatioForFullHdr = canonMax
            minDisplayRatioForHdrTransition = 1f
        }
    }

    companion object {
        private const val MIN_RATIO = 1f / 64f
        private const val DEFAULT_EPSILON = 1f / 64f

        /** Default resolution divisor for synthesized gain maps. */
        const val SYNTHESIS_DOWNSCALE = 4

        /** Gain applied to pure white when synthesizing HDR from SDR sources (1 stop). */
        const val SYNTHESIS_MAX_GAIN = 2f

        /** Luminance (0..1) where synthesized boost starts ramping in. */
        const val SYNTHESIS_LUMA_START = 0.6f

        fun log2(x: Float): Float = (ln(x.toDouble()) / ln(2.0)).toFloat()

        private fun smoothstep(edge0: Float, edge1: Float, x: Float): Float {
            if (edge1 <= edge0) {
                return if (x >= edge1) 1f else 0f
            }
            val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
            return t * t * (3f - 2f * t)
        }

        /**
         * Derives the canonical space covering every participating source.
         * [sourceRanges] holds (effectiveMinGain, effectiveMaxGain) per HDR source;
         * [includeSynthesis] reserves headroom for synthesized SDR boosts.
         */
        fun forSources(
            sourceRanges: List<Pair<Float, Float>>,
            includeSynthesis: Boolean,
        ): CanonicalGainmapSpace {
            var minGain = 1f
            var maxGain = if (includeSynthesis) SYNTHESIS_MAX_GAIN else 1f
            for ((srcMin, srcMax) in sourceRanges) {
                minGain = min(minGain, srcMin)
                maxGain = max(maxGain, srcMax)
            }
            minGain = minGain.coerceIn(MIN_RATIO, 1f)
            maxGain = max(maxGain, 1.0001f)
            return CanonicalGainmapSpace(minGain, maxGain)
        }

        /**
         * Converts a bitmap of any config into ARGB_8888 for pixel access.
         * ALPHA_8 gain maps become gray (value replicated into RGB).
         */
        fun ensureArgb(source: Bitmap): Bitmap {
            if (source.config == Bitmap.Config.ARGB_8888) {
                return source
            }
            val out = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            canvas.drawColor(Color.BLACK)
            val paint = Paint(Paint.FILTER_BITMAP_FLAG)
            if (source.config == Bitmap.Config.ALPHA_8) {
                // ALPHA_8 draws as a mask tinted by the paint color: white turns
                // the single channel into gray RGB values.
                paint.color = Color.WHITE
            }
            canvas.drawBitmap(source, 0f, 0f, paint)
            return out
        }
    }
}
