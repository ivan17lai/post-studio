package com.igapp.igapp.hdr

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.Typeface
import android.os.Build
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Renders one project page to JPEG bytes on the native side.
 *
 * This is the single Android export path: it composites image elements
 * (honoring crop, border radius and cross-page placement), draws text elements
 * with [TextPaint]/[StaticLayout], and — when `hdrMode` is not "off" on an
 * Android 14+ device — assembles an output gain map in a canonical space so the
 * result is a valid Ultra HDR JPEG even when sources carry different gain map
 * parameters or no gain map at all.
 *
 * `hdrMode` values:
 *  - "off":      plain SDR JPEG, no gain map attached.
 *  - "on":       gain maps of HDR sources are preserved; SDR content stays neutral.
 *  - "enhanced": additionally synthesizes a highlight boost for SDR images.
 */
object NativePageRenderer {
    private const val HDR_MODE_OFF = "off"
    private const val HDR_MODE_ON = "on"
    private const val HDR_MODE_ENHANCED = "enhanced"

    /** Line height multiplier used by the Flutter text renderer (height: 1.12). */
    private const val TEXT_LINE_HEIGHT = 1.12f

    /** Fixed gain applied to an "HDR white" page background (+1 stop). */
    private const val HDR_WHITE_BACKGROUND_GAIN = 2f

    fun render(payload: Map<String, Any>): ByteArray? {
        val exportWidth = (payload["exportWidth"] as? Number)?.toInt() ?: 2400
        val targetPageIndex = (payload["targetPageIndex"] as? Number)?.toInt() ?: 0
        val hdrMode = payload["hdrMode"] as? String ?: HDR_MODE_ON

        @Suppress("UNCHECKED_CAST")
        val pages = payload["pages"] as? List<Map<String, Any>> ?: return null
        if (targetPageIndex !in pages.indices) {
            return null
        }

        val pagePayload = pages[targetPageIndex]
        val aspectWidth = (pagePayload["aspectWidth"] as? Number)?.toDouble() ?: 1.0
        val aspectHeight = (pagePayload["aspectHeight"] as? Number)?.toDouble() ?: 1.0
        val exportHeight = (exportWidth * (aspectHeight / aspectWidth)).roundToInt()
        val backgroundColorValue =
            (pagePayload["backgroundColor"] as? Number)?.toInt() ?: 0xFFFFFFFF.toInt()

        val baseBitmap = Bitmap.createBitmap(exportWidth, exportHeight, Bitmap.Config.ARGB_8888)
        val baseCanvas = Canvas(baseBitmap)
        baseCanvas.drawColor(backgroundColorValue)

        val collectHdr =
            hdrMode != HDR_MODE_OFF &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
        val synthesizeSdr = collectHdr && hdrMode == HDR_MODE_ENHANCED
        // Only the target page's background fills the visible frame, so its
        // HDR-white flag is what drives the background gain fill.
        val backgroundHdr =
            collectHdr && (pagePayload["backgroundHdr"] as? Boolean ?: false)
        val gainmapOps = mutableListOf<GainmapOp>()
        var outputGainmapContents: Bitmap? = null
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

        try {
            for (sourcePageIndex in pages.indices) {
                val sourcePage = pages[sourcePageIndex]

                @Suppress("UNCHECKED_CAST")
                val elements = sourcePage["elements"] as? List<Map<String, Any>> ?: continue

                for (element in elements) {
                    val allowCrossPage = element["allowCrossPage"] as? Boolean ?: true
                    if (!allowCrossPage && sourcePageIndex != targetPageIndex) {
                        continue
                    }
                    val pageOffsetX = (sourcePageIndex - targetPageIndex) * exportWidth

                    when (element["type"] as? String) {
                        "image" -> drawImageElement(
                            element = element,
                            baseCanvas = baseCanvas,
                            paint = paint,
                            exportWidth = exportWidth,
                            exportHeight = exportHeight,
                            pageOffsetX = pageOffsetX,
                            collectHdr = collectHdr,
                            synthesizeSdr = synthesizeSdr,
                            gainmapOps = gainmapOps,
                        )
                        "text" -> drawTextElement(
                            element = element,
                            baseCanvas = baseCanvas,
                            exportWidth = exportWidth,
                            exportHeight = exportHeight,
                            pageOffsetX = pageOffsetX,
                            collectHdr = collectHdr,
                            gainmapOps = gainmapOps,
                        )
                    }
                }
            }

            if (collectHdr) {
                outputGainmapContents =
                    attachGainmapIfNeeded(baseBitmap, gainmapOps, backgroundHdr)
            }

            val outputStream = ByteArrayOutputStream()
            baseBitmap.compress(Bitmap.CompressFormat.JPEG, 100, outputStream)
            return outputStream.toByteArray()
        } finally {
            for (op in gainmapOps) {
                op.recycle()
            }
            baseBitmap.recycle()
            outputGainmapContents?.recycle()
        }
    }

    // region image elements

    private fun drawImageElement(
        element: Map<String, Any>,
        baseCanvas: Canvas,
        paint: Paint,
        exportWidth: Int,
        exportHeight: Int,
        pageOffsetX: Int,
        collectHdr: Boolean,
        synthesizeSdr: Boolean,
        gainmapOps: MutableList<GainmapOp>,
    ) {
        val src = element["src"] as? String ?: return
        if (src.isEmpty() || !File(src).exists()) {
            return
        }
        val sourceBitmap = UltraHdrSupport.decodeWithGainmap(src) ?: return

        try {
            val frameAspectRatio = (element["aspectRatio"] as? Number)?.toDouble()
                ?: (sourceBitmap.width.toDouble() / sourceBitmap.height.toDouble())
            val elementWidth = (element["width"] as? Number)?.toDouble() ?: 0.0
            val elementX = (element["x"] as? Number)?.toDouble() ?: 0.0
            val elementY = (element["y"] as? Number)?.toDouble() ?: 0.0

            val targetWidth = (elementWidth * exportWidth).roundToInt().coerceIn(1, 20000)
            val targetHeight = (targetWidth / frameAspectRatio).roundToInt().coerceIn(1, 20000)
            val targetX = (elementX * exportWidth).roundToInt() + pageOffsetX
            val targetY = (elementY * exportHeight).roundToInt()

            val cropRect = sourceCropRectForFrame(
                sourceBitmap.width,
                sourceBitmap.height,
                frameAspectRatio,
                (element["cropOffsetX"] as? Number)?.toDouble() ?: 0.0,
                (element["cropOffsetY"] as? Number)?.toDouble() ?: 0.0,
                (element["cropScale"] as? Number)?.toDouble() ?: 1.0,
            )
            val srcRect = Rect(
                cropRect.x,
                cropRect.y,
                cropRect.x + cropRect.width,
                cropRect.y + cropRect.height,
            )
            val dstRect = Rect(targetX, targetY, targetX + targetWidth, targetY + targetHeight)
            val borderRadiusRatio = (element["borderRadiusRatio"] as? Number)?.toDouble() ?: 0.0
            val radius =
                if (borderRadiusRatio > 0.0) {
                    (borderRadiusRatio * min(targetWidth, targetHeight)).toFloat()
                } else {
                    0f
                }

            withRoundedClip(baseCanvas, dstRect, radius) {
                baseCanvas.drawBitmap(sourceBitmap, srcRect, dstRect, paint)
            }

            if (collectHdr) {
                // hdrBrightness: 1 = unchanged. For HDR sources it scales the
                // existing gain; for SDR sources >1 it sets the synthesized peak.
                val brightness =
                    (element["hdrBrightness"] as? Number)?.toFloat()?.coerceIn(0f, 8f) ?: 1f
                gainmapOps += createImageGainmapOp(
                    sourceBitmap = sourceBitmap,
                    srcRect = srcRect,
                    dstRect = dstRect,
                    radius = radius,
                    synthesizeSdr = synthesizeSdr,
                    brightness = brightness,
                )
            }
        } finally {
            sourceBitmap.recycle()
        }
    }

    private fun createImageGainmapOp(
        sourceBitmap: Bitmap,
        srcRect: Rect,
        dstRect: Rect,
        radius: Float,
        synthesizeSdr: Boolean,
        brightness: Float,
    ): GainmapOp {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            sourceBitmap.hasGainmap()
        ) {
            val gainmap = sourceBitmap.gainmap
            val contents = gainmap?.gainmapContents
            if (gainmap != null && contents != null) {
                // Copy: the contents bitmap belongs to the source, which is recycled
                // right after this element is drawn.
                val contentsCopy =
                    if (contents.config == Bitmap.Config.ARGB_8888) {
                        contents.copy(Bitmap.Config.ARGB_8888, false)
                    } else {
                        CanonicalGainmapSpace.ensureArgb(contents)
                    }
                val scaleX = contents.width.toFloat() / sourceBitmap.width.toFloat()
                val scaleY = contents.height.toFloat() / sourceBitmap.height.toFloat()
                val gainmapSrcRect = Rect(
                    (srcRect.left * scaleX).roundToInt(),
                    (srcRect.top * scaleY).roundToInt(),
                    (srcRect.right * scaleX).roundToInt().coerceAtMost(contents.width),
                    (srcRect.bottom * scaleY).roundToInt().coerceAtMost(contents.height),
                )
                return GainmapOp.DrawSource(
                    contents = contentsCopy,
                    ratioMin = gainmap.ratioMin.copyOf(),
                    ratioMax = gainmap.ratioMax.copyOf(),
                    gamma = gainmap.gamma.copyOf(),
                    epsilonSdr = gainmap.epsilonSdr.copyOf(),
                    epsilonHdr = gainmap.epsilonHdr.copyOf(),
                    displayRatioForFullHdr = gainmap.displayRatioForFullHdr,
                    minDisplayRatioForHdrTransition = gainmap.minDisplayRatioForHdrTransition,
                    brightness = brightness,
                    srcRect = gainmapSrcRect,
                    dstRect = dstRect,
                    radius = radius,
                )
            }
        }

        // SDR source: synthesize when the user raised this image's brightness
        // above 1, or when the global "enhanced" mode is on. The synthesis peak
        // is the per-image brightness, falling back to the global default.
        val synthGain = max(brightness, if (synthesizeSdr) CanonicalGainmapSpace.SYNTHESIS_MAX_GAIN else 1f)
        if (synthGain > 1f) {
            val downscale = CanonicalGainmapSpace.SYNTHESIS_DOWNSCALE
            val smallWidth = (sourceBitmap.width / downscale).coerceAtLeast(1)
            val smallHeight = (sourceBitmap.height / downscale).coerceAtLeast(1)
            var small = Bitmap.createScaledBitmap(sourceBitmap, smallWidth, smallHeight, true)
            if (small === sourceBitmap) {
                small = sourceBitmap.copy(Bitmap.Config.ARGB_8888, false)
            }
            val scaleX = small.width.toFloat() / sourceBitmap.width.toFloat()
            val scaleY = small.height.toFloat() / sourceBitmap.height.toFloat()
            val smallSrcRect = Rect(
                (srcRect.left * scaleX).roundToInt(),
                (srcRect.top * scaleY).roundToInt(),
                (srcRect.right * scaleX).roundToInt().coerceAtMost(small.width),
                (srcRect.bottom * scaleY).roundToInt().coerceAtMost(small.height),
            )
            return GainmapOp.Synthesize(
                smallBase = small,
                srcRect = smallSrcRect,
                dstRect = dstRect,
                radius = radius,
                maxGain = synthGain,
            )
        }

        return GainmapOp.NeutralRect(dstRect = dstRect, radius = radius)
    }

    // endregion

    // region text elements

    private class TextSpec(
        val text: String,
        val color: Int,
        val fontSizePx: Float,
        val maxWidthPx: Int,
        val maxLines: Int,
        val x: Float,
        val y: Float,
        val maxClipHeight: Float,
    )

    private fun textSpecFromElement(
        element: Map<String, Any>,
        exportWidth: Int,
        exportHeight: Int,
        pageOffsetX: Int,
    ): TextSpec? {
        val text = (element["text"] as? String)?.ifEmpty { null } ?: return null
        val fontSizeRatio = (element["fontSizeRatio"] as? Number)?.toDouble() ?: return null
        val colorValue = (element["colorValue"] as? Number)?.toInt() ?: 0xFF111111.toInt()
        val maxLines = ((element["maxLines"] as? Number)?.toInt() ?: 1).coerceIn(1, 8)
        val elementWidth = (element["width"] as? Number)?.toDouble() ?: 0.0
        val elementX = (element["x"] as? Number)?.toDouble() ?: 0.0
        val elementY = (element["y"] as? Number)?.toDouble() ?: 0.0
        return TextSpec(
            text = text,
            color = colorValue,
            fontSizePx = (fontSizeRatio * exportWidth).toFloat(),
            maxWidthPx = (elementWidth * exportWidth).roundToInt().coerceIn(1, 20000),
            maxLines = maxLines,
            x = (elementX * exportWidth).toFloat() + pageOffsetX,
            y = (elementY * exportHeight).toFloat(),
            maxClipHeight = exportHeight.toFloat(),
        )
    }

    private fun drawTextElement(
        element: Map<String, Any>,
        baseCanvas: Canvas,
        exportWidth: Int,
        exportHeight: Int,
        pageOffsetX: Int,
        collectHdr: Boolean,
        gainmapOps: MutableList<GainmapOp>,
    ) {
        val spec = textSpecFromElement(element, exportWidth, exportHeight, pageOffsetX) ?: return
        drawTextSpec(baseCanvas, spec, spec.color)
        if (collectHdr) {
            gainmapOps += GainmapOp.NeutralText(spec)
        }
    }

    /** Mirrors the Flutter export text rendering (Roboto w700, height 1.12, top-left clip). */
    private fun drawTextSpec(canvas: Canvas, spec: TextSpec, color: Int) {
        val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            textSize = spec.fontSizePx
            typeface =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    Typeface.create(Typeface.DEFAULT, 700, false)
                } else {
                    Typeface.DEFAULT_BOLD
                }
        }
        val metrics = textPaint.fontMetrics
        val naturalLineHeight = metrics.descent - metrics.ascent
        val spacingMultiplier =
            if (naturalLineHeight > 0f) {
                TEXT_LINE_HEIGHT * spec.fontSizePx / naturalLineHeight
            } else {
                1f
            }
        val layout = StaticLayout.Builder
            .obtain(spec.text, 0, spec.text.length, textPaint, spec.maxWidthPx)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(false)
            .setLineSpacing(0f, spacingMultiplier)
            .setMaxLines(spec.maxLines)
            .build()
        val clipHeight = layout.height.toFloat().coerceIn(1f, spec.maxClipHeight)

        canvas.save()
        canvas.clipRect(spec.x, spec.y, spec.x + spec.maxWidthPx, spec.y + clipHeight)
        canvas.translate(spec.x, spec.y)
        layout.draw(canvas)
        canvas.restore()
    }

    // endregion

    // region gain map assembly

    private sealed interface GainmapOp {
        fun recycle() {}

        class DrawSource(
            val contents: Bitmap,
            val ratioMin: FloatArray,
            val ratioMax: FloatArray,
            val gamma: FloatArray,
            val epsilonSdr: FloatArray,
            val epsilonHdr: FloatArray,
            val displayRatioForFullHdr: Float,
            val minDisplayRatioForHdrTransition: Float,
            val brightness: Float,
            val srcRect: Rect,
            val dstRect: Rect,
            val radius: Float,
        ) : GainmapOp {
            override fun recycle() = contents.recycle()
        }

        class Synthesize(
            val smallBase: Bitmap,
            val srcRect: Rect,
            val dstRect: Rect,
            val radius: Float,
            val maxGain: Float,
        ) : GainmapOp {
            override fun recycle() = smallBase.recycle()
        }

        class NeutralRect(val dstRect: Rect, val radius: Float) : GainmapOp

        class NeutralText(val spec: TextSpec) : GainmapOp
    }

    /**
     * Builds the output gain map by replaying the collected per-element ops in
     * z-order inside a canonical space derived from every participating source,
     * then attaches it to [baseBitmap]. Skips attaching when the page carries no
     * HDR signal at all (pure SDR pages stay plain JPEGs).
     *
     * Returns the gain map contents bitmap so the caller can recycle it once
     * the page has been compressed.
     */
    private fun attachGainmapIfNeeded(
        baseBitmap: Bitmap,
        gainmapOps: List<GainmapOp>,
        backgroundHdr: Boolean,
    ): Bitmap? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return null
        }
        val hdrSources = gainmapOps.filterIsInstance<GainmapOp.DrawSource>()
        val synthOps = gainmapOps.filterIsInstance<GainmapOp.Synthesize>()
        val hasSynthesis = synthOps.isNotEmpty()
        // Nothing carries an HDR signal — keep the page a plain SDR JPEG.
        if (hdrSources.isEmpty() && !hasSynthesis && !backgroundHdr) {
            return null
        }

        // Headroom reserved on top of the HDR sources: synthesized SDR peaks and
        // the HDR-white background both push the canonical max up.
        var extraMaxGain = 1f
        for (op in synthOps) {
            extraMaxGain = max(extraMaxGain, op.maxGain)
        }
        if (backgroundHdr) {
            extraMaxGain = max(extraMaxGain, HDR_WHITE_BACKGROUND_GAIN)
        }

        val space = CanonicalGainmapSpace.forSources(
            sourceRanges = hdrSources.map { op ->
                // Per-image brightness scales the gain in log space, so the
                // source's effective ratios are raised to the brightness power.
                val effectiveMin =
                    minOf(op.ratioMin[0], op.ratioMin[1], op.ratioMin[2]).pow(op.brightness)
                val effectiveMax =
                    maxOf(op.ratioMax[0], op.ratioMax[1], op.ratioMax[2]).pow(op.brightness)
                effectiveMin to effectiveMax
            },
            extraMaxGain = extraMaxGain,
        )

        val gainmapBitmap =
            Bitmap.createBitmap(baseBitmap.width, baseBitmap.height, Bitmap.Config.ARGB_8888)
        val gainmapCanvas = Canvas(gainmapBitmap)
        // The background fill is the gain every uncovered pixel reads: HDR-white
        // boosts it, otherwise it stays neutral (SDR) so plain backgrounds and
        // SDR images keep their exact look.
        val backgroundFillColor =
            if (backgroundHdr) {
                val v = space.encodeLog2(CanonicalGainmapSpace.log2(HDR_WHITE_BACKGROUND_GAIN))
                Color.rgb(v, v, v)
            } else {
                space.neutralColor
            }
        gainmapCanvas.drawColor(backgroundFillColor)
        val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = space.neutralColor }

        for (op in gainmapOps) {
            when (op) {
                is GainmapOp.DrawSource -> {
                    val remapped =
                        space.remapContents(
                            op.contents,
                            op.ratioMin,
                            op.ratioMax,
                            op.gamma,
                            op.brightness,
                        )
                    withRoundedClip(gainmapCanvas, op.dstRect, op.radius) {
                        gainmapCanvas.drawBitmap(remapped, op.srcRect, op.dstRect, bitmapPaint)
                    }
                    remapped.recycle()
                }
                is GainmapOp.Synthesize -> {
                    val synthesized =
                        space.synthesizeFromSdr(op.smallBase, downscale = 1, maxGain = op.maxGain)
                    withRoundedClip(gainmapCanvas, op.dstRect, op.radius) {
                        gainmapCanvas.drawBitmap(synthesized, op.srcRect, op.dstRect, bitmapPaint)
                    }
                    synthesized.recycle()
                }
                is GainmapOp.NeutralRect -> {
                    withRoundedClip(gainmapCanvas, op.dstRect, op.radius) {
                        gainmapCanvas.drawRect(op.dstRect, fillPaint)
                    }
                }
                is GainmapOp.NeutralText -> {
                    // Text replaces base pixels, so its glyphs must read as
                    // "no gain" in the gain map regardless of what sits below.
                    drawTextSpec(gainmapCanvas, op.spec, space.neutralColor)
                }
            }
        }

        // Carry the HDR rendering metadata from the real sources so the rebuilt
        // gain map reaches full strength at the same display headroom as the
        // originals — otherwise the export looks dimmer than the live preview,
        // which renders the source gain map directly. With several HDR sources we
        // take the widest transition (max displayRatioForFullHdr, min transition
        // floor) so no source is pushed past its intended peak.
        val capMax: Float
        val capMin: Float
        val epsilonSdr: FloatArray
        val epsilonHdr: FloatArray
        if (hdrSources.isNotEmpty()) {
            var cMax = 1f
            var cMin = Float.MAX_VALUE
            val eS = floatArrayOf(0f, 0f, 0f)
            val eH = floatArrayOf(0f, 0f, 0f)
            for (op in hdrSources) {
                cMax = max(cMax, op.displayRatioForFullHdr)
                cMin = min(cMin, op.minDisplayRatioForHdrTransition)
                for (c in 0..2) {
                    eS[c] = max(eS[c], op.epsilonSdr[c])
                    eH[c] = max(eH[c], op.epsilonHdr[c])
                }
            }
            // Keep the transition within the (possibly brightness-widened)
            // canonical range so displayRatioForFullHdr never exceeds ratioMax.
            capMax = cMax.coerceAtMost(space.canonMax)
            capMin = if (cMin == Float.MAX_VALUE) 1f else cMin
            epsilonSdr = eS
            epsilonHdr = eH
        } else {
            capMax = space.canonMax
            capMin = 1f
            epsilonSdr = CanonicalGainmapSpace.defaultEpsilon()
            epsilonHdr = CanonicalGainmapSpace.defaultEpsilon()
        }

        baseBitmap.gainmap =
            space.toGainmap(gainmapBitmap, capMax, capMin, epsilonSdr, epsilonHdr)
        return gainmapBitmap
    }

    // endregion

    // region geometry helpers

    private inline fun withRoundedClip(
        canvas: Canvas,
        dstRect: Rect,
        radius: Float,
        block: () -> Unit,
    ) {
        if (radius <= 0f) {
            block()
            return
        }
        canvas.save()
        val path = Path().apply {
            addRoundRect(
                dstRect.left.toFloat(),
                dstRect.top.toFloat(),
                dstRect.right.toFloat(),
                dstRect.bottom.toFloat(),
                radius,
                radius,
                Path.Direction.CW,
            )
        }
        canvas.clipPath(path)
        block()
        canvas.restore()
    }

    private data class CropRect(val x: Int, val y: Int, val width: Int, val height: Int)

    private fun sourceCropRectForFrame(
        sourceWidth: Int,
        sourceHeight: Int,
        frameAspectRatio: Double,
        cropOffsetX: Double,
        cropOffsetY: Double,
        cropScale: Double,
    ): CropRect {
        val safeFrameAspectRatio = if (frameAspectRatio <= 0) 1.0 else frameAspectRatio
        val sourceAspectRatio = sourceWidth.toDouble() / sourceHeight.toDouble()
        val safeScale = if (cropScale < 1.0) 1.0 else cropScale
        val frameHeight = 1.0
        val frameWidth = safeFrameAspectRatio
        var imageWidth: Double
        var imageHeight: Double

        if (sourceAspectRatio > safeFrameAspectRatio) {
            imageHeight = frameHeight
            imageWidth = imageHeight * sourceAspectRatio
        } else {
            imageWidth = frameWidth
            imageHeight = imageWidth / sourceAspectRatio
        }

        imageWidth *= safeScale
        imageHeight *= safeScale

        val left = clampCropImageOffset(
            ((frameWidth - imageWidth) / 2) + (cropOffsetX * frameWidth),
            frameWidth - imageWidth,
            0.0,
        )
        val top = clampCropImageOffset(
            ((frameHeight - imageHeight) / 2) + (cropOffsetY * frameHeight),
            frameHeight - imageHeight,
            0.0,
        )

        val x = ((-left / imageWidth) * sourceWidth).roundToInt().coerceIn(0, sourceWidth - 1)
        val y = ((-top / imageHeight) * sourceHeight).roundToInt().coerceIn(0, sourceHeight - 1)
        val width =
            ((frameWidth / imageWidth) * sourceWidth).roundToInt().coerceIn(1, sourceWidth - x)
        val height =
            ((frameHeight / imageHeight) * sourceHeight).roundToInt().coerceIn(1, sourceHeight - y)

        return CropRect(x, y, width, height)
    }

    private fun clampCropImageOffset(value: Double, min: Double, max: Double): Double {
        if (min >= max) {
            return 0.0
        }
        return value.coerceIn(min, max)
    }

    // endregion
}
