package com.igapp.igapp.hdr

import android.content.Context
import android.graphics.Bitmap
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
 * Decoding happens off the UI thread and is capped to a screen-friendly size
 * (the gain map is scaled along with the base image).
 */
class HdrImageView(context: Context, creationParams: Map<String, Any?>?) : PlatformView {
    private val imageView = ImageView(context)

    @Volatile
    private var disposed = false
    private var bitmap: Bitmap? = null

    init {
        imageView.scaleType =
            if (creationParams?.get("fit") == "contain") {
                ImageView.ScaleType.FIT_CENTER
            } else {
                ImageView.ScaleType.FIT_XY
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
                mainHandler.post {
                    if (disposed) {
                        decoded?.recycle()
                        return@post
                    }
                    if (decoded != null) {
                        bitmap = decoded
                        imageView.setImageBitmap(decoded)
                    }
                }
            }
        }
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
