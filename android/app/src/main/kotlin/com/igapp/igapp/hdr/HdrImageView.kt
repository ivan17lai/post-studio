package com.igapp.igapp.hdr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.ImageView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Platform view that displays an image with its gain map intact, so Ultra HDR
 * photos render with real HDR headroom while the window is in HDR color mode.
 *
 * Accepts optional crop parameters (sourceAspectRatio, cropOffsetX/Y, cropScale)
 * to position the image inside the view exactly as Flutter's _CroppedImageFile
 * does, but with the gain map preserved for true HDR rendering.
 */
class HdrImageView(context: Context, creationParams: Map<String, Any?>?) : PlatformView {
    private val imageView = ImageView(context)

    @Volatile
    private var disposed = false
    private var bitmap: Bitmap? = null

    private data class CropParams(
        val sourceAspectRatio: Float,
        val cropOffsetX: Float,
        val cropOffsetY: Float,
        val cropScale: Float,
    )

    private val hdrBrightness: Float =
        (creationParams?.get("hdrBrightness") as? Number)?.toFloat() ?: 1f

    private val cropParams: CropParams? = creationParams?.let { params ->
        val srcAR = (params["sourceAspectRatio"] as? Number)?.toFloat()
        if (srcAR != null && srcAR > 0f) {
            CropParams(
                sourceAspectRatio = srcAR,
                cropOffsetX = (params["cropOffsetX"] as? Number)?.toFloat() ?: 0f,
                cropOffsetY = (params["cropOffsetY"] as? Number)?.toFloat() ?: 0f,
                cropScale = ((params["cropScale"] as? Number)?.toFloat() ?: 1f)
                    .coerceAtLeast(1f),
            )
        } else null
    }

    init {
        imageView.scaleType = when {
            cropParams != null -> ImageView.ScaleType.MATRIX
            creationParams?.get("fit") == "contain" -> ImageView.ScaleType.FIT_CENTER
            else -> ImageView.ScaleType.FIT_XY
        }

        val path = creationParams?.get("path") as? String
        if (path != null) {
            decodeExecutor.execute {
                val decoded =
                    try {
                        UltraHdrSupport.decodeWithGainmap(path, maxSide = MAX_DECODE_SIDE)
                            ?.let { UltraHdrSupport.applyPreviewBrightness(it, hdrBrightness) }
                    } catch (_: Exception) {
                        null
                    }
                mainHandler.post {
                    if (disposed) {
                        decoded?.recycle()
                        return@post
                    }
                    if (decoded != null) {
                        bitmap = decoded
                        imageView.setImageBitmap(decoded)
                        applyCropMatrix()
                    }
                }
            }
        }

        if (cropParams != null) {
            imageView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                applyCropMatrix()
            }
        }
    }

    /**
     * Mirrors the crop geometry from Flutter's _CroppedImageFile:
     * scale the bitmap so the source aspect ratio fills the frame, then apply
     * cropScale and clamp-clamped cropOffset translation.
     */
    private fun applyCropMatrix() {
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

        val left = ((vW - scaledW) / 2f + cp.cropOffsetX * vW)
            .coerceIn(vW - scaledW, 0f)
        val top = ((vH - scaledH) / 2f + cp.cropOffsetY * vH)
            .coerceIn(vH - scaledH, 0f)

        val matrix = Matrix()
        matrix.setScale(scaledW / bm.width.toFloat(), scaledH / bm.height.toFloat())
        matrix.postTranslate(left, top)
        imageView.imageMatrix = matrix
    }

    override fun getView(): View = imageView

    override fun dispose() {
        disposed = true
        imageView.setImageDrawable(null)
        bitmap?.recycle()
        bitmap = null
    }

    companion object {
        private const val MAX_DECODE_SIDE = 2048
        private val decodeExecutor: ExecutorService = Executors.newSingleThreadExecutor()
        private val mainHandler = Handler(Looper.getMainLooper())
    }
}

class HdrImageViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val creationParams = args as? Map<String, Any?>
        return HdrImageView(context, creationParams)
    }
}
