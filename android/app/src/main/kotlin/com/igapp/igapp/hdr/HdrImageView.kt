package com.igapp.igapp.hdr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Gainmap
import android.graphics.Matrix
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.ImageView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Platform view that displays an image with its gain map intact (true HDR via
 * hybrid composition on the Flutter side).
 *
 * The base image is decoded once; the per-image "deep adjust" parameters
 * (HDR brightness, colour matrix, highlights/shadows tone curve, HDR/SDR view)
 * are pushed live over a per-view [MethodChannel] (`igapp/hdr_image_view/<id>`)
 * so dragging a slider updates the same view in place instead of recreating the
 * platform view — which is what used to cause the flicker.
 */
class HdrImageView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
    creationParams: Map<String, Any?>?,
) : PlatformView {
    private val imageView = ImageView(context)
    private val channel = MethodChannel(messenger, "igapp/hdr_image_view/$viewId")

    @Volatile
    private var disposed = false

    /** Decoded SDR base + its original gain map, captured once. */
    private var base: Bitmap? = null
    private var baseGainmap: Gainmap? = null
    private var baseHasGainmap = false

    /** The derived bitmap currently shown (null when the base itself is shown). */
    private var displayedDerived: Bitmap? = null

    private val renderScheduled = AtomicBoolean(false)

    private data class CropParams(
        val sourceAspectRatio: Float,
        val cropOffsetX: Float,
        val cropOffsetY: Float,
        val cropScale: Float,
    )

    private class AdjustParams(
        @Volatile var hdrBrightness: Float = 1f,
        @Volatile var colorFilter: android.graphics.ColorMatrixColorFilter? = null,
        @Volatile var highlights: Float = 0f,
        @Volatile var shadows: Float = 0f,
        @Volatile var hdrView: Boolean = true,
    )

    private val params = AdjustParams()

    private val cropParams: CropParams? = creationParams?.let { p ->
        val srcAR = (p["sourceAspectRatio"] as? Number)?.toFloat()
        if (srcAR != null && srcAR > 0f) {
            CropParams(
                sourceAspectRatio = srcAR,
                cropOffsetX = (p["cropOffsetX"] as? Number)?.toFloat() ?: 0f,
                cropOffsetY = (p["cropOffsetY"] as? Number)?.toFloat() ?: 0f,
                cropScale = ((p["cropScale"] as? Number)?.toFloat() ?: 1f).coerceAtLeast(1f),
            )
        } else null
    }

    init {
        imageView.scaleType = when {
            cropParams != null -> ImageView.ScaleType.MATRIX
            creationParams?.get("fit") == "contain" -> ImageView.ScaleType.FIT_CENTER
            else -> ImageView.ScaleType.FIT_XY
        }
        readParams(creationParams)

        channel.setMethodCallHandler { call, result ->
            if (call.method == "setParams") {
                @Suppress("UNCHECKED_CAST")
                readParams(call.arguments as? Map<String, Any?>)
                scheduleRender()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        if (cropParams != null) {
            imageView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                applyCropMatrix()
            }
        }

        val path = creationParams?.get("path") as? String
        if (path != null) {
            decodeExecutor.execute {
                val decoded =
                    try {
                        UltraHdrSupport.decodeWithGainmap(path, maxSide = MAX_DECODE_SIDE)
                    } catch (_: Exception) {
                        null
                    }
                if (decoded == null) return@execute
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                    decoded.hasGainmap()
                ) {
                    baseGainmap = decoded.gainmap
                    baseHasGainmap = true
                }
                base = decoded
                renderNow()
            }
        }
    }

    private fun readParams(raw: Map<String, Any?>?) {
        if (raw == null) return
        (raw["hdrBrightness"] as? Number)?.let { params.hdrBrightness = it.toFloat().coerceIn(0f, 8f) }
        if (raw.containsKey("colorMatrix")) {
            params.colorFilter = PhotoAdjust.colorMatrixFilter(raw["colorMatrix"])
        }
        (raw["highlights"] as? Number)?.let { params.highlights = it.toFloat().coerceIn(-1f, 1f) }
        (raw["shadows"] as? Number)?.let { params.shadows = it.toFloat().coerceIn(-1f, 1f) }
        (raw["hdrView"] as? Boolean)?.let { params.hdrView = it }
    }

    /** Coalesced render: collapses a burst of slider updates into one pass. */
    private fun scheduleRender() {
        if (renderScheduled.compareAndSet(false, true)) {
            decodeExecutor.execute {
                renderScheduled.set(false)
                renderNow()
            }
        }
    }

    private fun renderNow() {
        if (disposed) return
        val src = base ?: return
        val hdrView = params.hdrView
        val brightness = params.hdrBrightness
        val filter = params.colorFilter

        // Highlights/shadows tone curve (new bitmap when non-neutral).
        val working = PhotoAdjust.applyToneCurve(src, params.highlights, params.shadows)

        // Decide the gain map of the shown bitmap, always derived from the
        // captured original so repeated updates don't compound.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            working.gainmap = when {
                !hdrView -> null
                baseHasGainmap -> baseGainmap?.let {
                    if (brightness == 1f) it else CanonicalGainmapSpace.scaledGainmap(it, brightness)
                }
                brightness > 1f -> synthesizeFor(working, brightness)
                else -> null
            }
        }

        mainHandler.post {
            if (disposed) {
                if (working !== src) working.recycle()
                return@post
            }
            val previous = displayedDerived
            imageView.colorFilter = filter
            imageView.setImageBitmap(working)
            applyCropMatrix(working)
            displayedDerived = if (working !== src) working else null
            if (previous != null && previous !== working && previous !== src) {
                previous.recycle()
            }
        }
    }

    private fun synthesizeFor(sdrBase: Bitmap, brightness: Float): Gainmap? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
        val space = CanonicalGainmapSpace.forSources(emptyList(), brightness)
        val contents = space.synthesizeFromSdr(
            sdrBase,
            downscale = CanonicalGainmapSpace.SYNTHESIS_DOWNSCALE,
            maxGain = brightness,
        )
        return space.toGainmap(
            contents,
            brightness,
            1f,
            CanonicalGainmapSpace.defaultEpsilon(),
            CanonicalGainmapSpace.defaultEpsilon(),
        )
    }

    private fun applyCropMatrix(bitmap: Bitmap? = displayedBitmap()) {
        val cp = cropParams ?: return
        val bm = bitmap ?: return
        val vW = imageView.width.toFloat()
        val vH = imageView.height.toFloat()
        if (vW <= 0f || vH <= 0f) return

        val frameAR = vW / vH
        val imgW: Float
        val imgH: Float
        if (cp.sourceAspectRatio > frameAR) {
            imgH = vH
            imgW = imgH * cp.sourceAspectRatio
        } else {
            imgW = vW
            imgH = imgW / cp.sourceAspectRatio
        }
        val scaledW = imgW * cp.cropScale
        val scaledH = imgH * cp.cropScale
        val left = ((vW - scaledW) / 2f + cp.cropOffsetX * vW).coerceIn(vW - scaledW, 0f)
        val top = ((vH - scaledH) / 2f + cp.cropOffsetY * vH).coerceIn(vH - scaledH, 0f)

        val matrix = Matrix()
        matrix.setScale(scaledW / bm.width.toFloat(), scaledH / bm.height.toFloat())
        matrix.postTranslate(left, top)
        imageView.imageMatrix = matrix
    }

    private fun displayedBitmap(): Bitmap? = displayedDerived ?: base

    override fun getView(): View = imageView

    override fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        imageView.setImageDrawable(null)
        displayedDerived?.recycle()
        displayedDerived = null
        base?.recycle()
        base = null
        baseGainmap = null
    }

    companion object {
        private const val MAX_DECODE_SIDE = 2048
        private val decodeExecutor: ExecutorService = Executors.newSingleThreadExecutor()
        private val mainHandler = Handler(Looper.getMainLooper())
    }
}

class HdrImageViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val creationParams = args as? Map<String, Any?>
        return HdrImageView(context, viewId, messenger, creationParams)
    }
}
