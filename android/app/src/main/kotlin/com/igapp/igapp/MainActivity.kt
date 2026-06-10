package com.igapp.igapp

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Gainmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.view.View
import android.widget.ImageView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val pendingSharedImagePaths = mutableListOf<String>()
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            window.colorMode = ActivityInfo.COLOR_MODE_HDR
        }
        queueSharedImagesFromIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "igapp/hdr_image_view",
            HdrImageViewFactory()
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "igapp/gallery",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveJpgToGallery" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("name")

                    if (bytes == null || name.isNullOrBlank()) {
                        result.error("invalid_args", "Missing image bytes or name.", null)
                        return@setMethodCallHandler
                    }

                    result.success(saveJpgToGallery(bytes, name))
                }
                "prepareImageAsset" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val projectId = call.argument<String>("projectId")
                    val maxPreviewSide = call.argument<Int>("maxPreviewSide") ?: 1440

                    if (sourcePath.isNullOrBlank() || projectId.isNullOrBlank()) {
                        result.error("invalid_args", "Missing sourcePath or projectId.", null)
                        return@setMethodCallHandler
                    }

                    ioExecutor.execute {
                        try {
                            val prepared = prepareImageAsset(sourcePath, projectId, maxPreviewSide)
                            runOnUiThread { result.success(prepared) }
                        } catch (exception: Exception) {
                            runOnUiThread {
                                result.error(
                                    "prepare_image_failed",
                                    exception.message ?: "prepareImageAsset failed",
                                    null,
                                )
                            }
                        }
                    }
                }
                "readImageBytesForExport" -> {
                    val path = call.argument<String>("path")

                    if (path.isNullOrBlank()) {
                        result.error("invalid_args", "Missing image path.", null)
                        return@setMethodCallHandler
                    }

                    ioExecutor.execute {
                        try {
                            val bytes = readImageBytesForExport(path)
                            runOnUiThread { result.success(bytes) }
                        } catch (exception: Exception) {
                            runOnUiThread {
                                result.error(
                                    "read_image_failed",
                                    exception.message ?: "readImageBytesForExport failed",
                                    null,
                                )
                            }
                        }
                    }
                }
                "renderPageToJpgNative" -> {
                    val payload = call.arguments as? Map<String, Any>
                    if (payload == null) {
                        result.error("invalid_args", "Missing payload map.", null)
                        return@setMethodCallHandler
                    }

                    ioExecutor.execute {
                        try {
                            val bytes = renderPageToJpgNative(payload)
                            runOnUiThread { result.success(bytes) }
                        } catch (exception: Exception) {
                            runOnUiThread {
                                result.error(
                                    "render_failed",
                                    exception.message ?: "renderPageToJpgNative failed",
                                    null,
                                )
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        shareChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "igapp/share",
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getPendingSharedImages" -> {
                            result.success(ArrayList(pendingSharedImagePaths))
                            pendingSharedImagePaths.clear()
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val sharedPaths = extractSharedImagePaths(intent)
        if (sharedPaths.isEmpty()) {
            return
        }
        pendingSharedImagePaths.addAll(sharedPaths)
        shareChannel?.invokeMethod("sharedImagesReceived", ArrayList(sharedPaths))
    }

    private fun queueSharedImagesFromIntent(intent: Intent?) {
        val sharedPaths = extractSharedImagePaths(intent)
        if (sharedPaths.isNotEmpty()) {
            pendingSharedImagePaths.addAll(sharedPaths)
        }
    }

    private fun extractSharedImagePaths(intent: Intent?): List<String> {
        if (intent == null) {
            return emptyList()
        }

        val action = intent.action
        val type = intent.type
        if (type == null || !type.startsWith("image/")) {
            return emptyList()
        }

        val uris =
            when (action) {
                Intent.ACTION_SEND -> {
                    listOfNotNull(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(Intent.EXTRA_STREAM)
                        },
                    )
                }
                Intent.ACTION_SEND_MULTIPLE -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                            ?: arrayListOf()
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM) ?: arrayListOf()
                    }
                }
                else -> emptyList()
            }

        if (uris.isEmpty()) {
            return emptyList()
        }

        val importsDir = File(cacheDir, "shared_imports").apply { mkdirs() }
        val copiedPaths = mutableListOf<String>()
        uris.forEachIndexed { index, uri ->
            try {
                copySharedUriToTempFile(uri, importsDir, index)?.let { copiedPaths.add(it) }
            } catch (_: Exception) {
            }
        }
        return copiedPaths
    }

    private fun copySharedUriToTempFile(
        uri: Uri,
        importsDir: File,
        index: Int,
    ): String? {
        val resolver = applicationContext.contentResolver
        val extension =
            resolver.getType(uri)?.substringAfter('/')?.substringBefore(';')?.ifBlank { null }
                ?: "jpg"
        val targetFile =
            File(importsDir, "shared_${System.currentTimeMillis()}_${index}.$extension")

        resolver.openInputStream(uri)?.use { input ->
            FileOutputStream(targetFile).use { output ->
                input.copyTo(output)
                output.flush()
            }
        } ?: return null

        return targetFile.absolutePath
    }

    private fun sha256OfFile(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        FileInputStream(file).use { input ->
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) {
                    break
                }
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }

    private fun prepareImageAsset(
        sourcePath: String,
        projectId: String,
        maxPreviewSide: Int,
    ): Map<String, Any> {
        val sourceFile = File(sourcePath)
        require(sourceFile.exists()) { "Source image does not exist." }

        val originalsDir =
            File(filesDir, "project_images${File.separator}$projectId${File.separator}originals").apply {
                mkdirs()
            }
        val previewsDir =
            File(filesDir, "project_images${File.separator}$projectId${File.separator}previews").apply {
                mkdirs()
            }

        val extension = sourceFile.extension.lowercase().ifBlank { "jpg" }
        val hashedName = sha256OfFile(sourceFile)
        val originalFile = File(originalsDir, "$hashedName.$extension")
        if (sourceFile.absolutePath != originalFile.absolutePath && !originalFile.exists()) {
            sourceFile.copyTo(originalFile, overwrite = false)
        }

        val bounds =
            BitmapFactory.Options().apply {
                inJustDecodeBounds = true
                BitmapFactory.decodeFile(originalFile.absolutePath, this)
            }
        val sourceWidth = bounds.outWidth
        val sourceHeight = bounds.outHeight
        require(sourceWidth > 0 && sourceHeight > 0) { "Invalid source image size." }

        val longestSide = maxOf(sourceWidth, sourceHeight)
        if (longestSide <= maxPreviewSide) {
            return mapOf(
                "displayPath" to originalFile.absolutePath,
                "originalPath" to originalFile.absolutePath,
                "width" to sourceWidth.toDouble(),
                "height" to sourceHeight.toDouble(),
            )
        }

        val resizedBitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                val source = ImageDecoder.createSource(originalFile)
                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    decoder.isMutableRequired = true
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    val scale = maxPreviewSide.toFloat() / maxOf(info.size.width, info.size.height)
                    if (scale < 1.0f) {
                        val targetW = (info.size.width * scale).toInt().coerceAtLeast(1)
                        val targetH = (info.size.height * scale).toInt().coerceAtLeast(1)
                        decoder.setTargetSize(targetW, targetH)
                    }
                }
            } catch (e: Exception) {
                decodeAndScaleLegacy(originalFile.absolutePath, sourceWidth, sourceHeight, maxPreviewSide)
            }
        } else {
            decodeAndScaleLegacy(originalFile.absolutePath, sourceWidth, sourceHeight, maxPreviewSide)
        }

        val previewExtension = if (extension == "png") "png" else "jpg"
        val previewFile = File(previewsDir, "$hashedName.$previewExtension")
        FileOutputStream(previewFile).use { output ->
            val format =
                if (previewExtension == "png") {
                    Bitmap.CompressFormat.PNG
                } else {
                    Bitmap.CompressFormat.JPEG
                }
            resizedBitmap.compress(format, 90, output)
            output.flush()
        }
        resizedBitmap.recycle()

        return mapOf(
            "displayPath" to previewFile.absolutePath,
            "originalPath" to originalFile.absolutePath,
            "width" to sourceWidth.toDouble(),
            "height" to sourceHeight.toDouble(),
        )
    }

    private fun computeInSampleSize(
        width: Int,
        height: Int,
        maxPreviewSide: Int,
    ): Int {
        var sampleSize = 1
        var currentWidth = width
        var currentHeight = height
        while (maxOf(currentWidth, currentHeight) > maxPreviewSide * 2) {
            sampleSize *= 2
            currentWidth /= 2
            currentHeight /= 2
        }
        return sampleSize.coerceAtLeast(1)
    }

    private fun decodeAndScaleLegacy(path: String, width: Int, height: Int, maxPreviewSide: Int): Bitmap {
        val sampleSize = computeInSampleSize(width, height, maxPreviewSide)
        val decodeOptions =
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
        val decoded = BitmapFactory.decodeFile(path, decodeOptions) ?: error("Failed to decode image")
        return if (maxOf(decoded.width, decoded.height) <= maxPreviewSide) {
            decoded
        } else {
            val scale = maxPreviewSide.toFloat() / maxOf(decoded.width, decoded.height)
            val newW = (decoded.width * scale).toInt().coerceAtLeast(1)
            val newH = (decoded.height * scale).toInt().coerceAtLeast(1)
            Bitmap.createScaledBitmap(decoded, newW, newH, true).also {
                if (it != decoded) {
                    decoded.recycle()
                }
            }
        }
    }

    private fun readImageBytesForExport(path: String): ByteArray {
        val file = File(path)
        require(file.exists()) { "Image does not exist." }

        return file.readBytes()
    }

    private fun saveJpgToGallery(bytes: ByteArray, name: String): Boolean {
        val resolver = applicationContext.contentResolver
        val values =
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, "$name.jpg")
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/IGApp",
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            }

        val uri =
            resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: return false

        return try {
            resolver.openOutputStream(uri)?.use { stream ->
                stream.write(bytes)
                stream.flush()
            } ?: return false

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }

            true
        } catch (_: IOException) {
            resolver.delete(uri, null, null)
            false
        }
    }

    private fun renderPageToJpgNative(payload: Map<String, Any>): ByteArray? {
        val exportWidth = (payload["exportWidth"] as? Number)?.toInt() ?: 2400
        val targetPageIndex = (payload["targetPageIndex"] as? Number)?.toInt() ?: 0
        val pages = payload["pages"] as? List<Map<String, Any>> ?: return null

        val pagePayload = pages[targetPageIndex]
        val aspectWidth = (pagePayload["aspectWidth"] as? Number)?.toDouble() ?: 1.0
        val aspectHeight = (pagePayload["aspectHeight"] as? Number)?.toDouble() ?: 1.0
        val exportHeight = (exportWidth * (aspectHeight / aspectWidth)).roundToInt()

        val backgroundColorValue = (pagePayload["backgroundColor"] as? Number)?.toInt() ?: 0xFFFFFFFF.toInt()

        // Create base bitmap
        val baseBitmap = Bitmap.createBitmap(exportWidth, exportHeight, Bitmap.Config.ARGB_8888)
        val baseCanvas = Canvas(baseBitmap)
        baseCanvas.drawColor(backgroundColorValue)

        var finalGainmapBitmap: Bitmap? = null
        var finalGainmapCanvas: Canvas? = null
        var copiedGainmapParams: Gainmap? = null

        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

        for (sourcePageIndex in pages.indices) {
            val sourcePage = pages[sourcePageIndex]
            val elements = sourcePage["elements"] as? List<Map<String, Any>> ?: continue

            for (element in elements) {
                val type = element["type"] as? String
                if (type != "image") continue

                val allowCrossPage = element["allowCrossPage"] as? Boolean ?: true
                if (!allowCrossPage && sourcePageIndex != targetPageIndex) {
                    continue
                }

                val src = element["src"] as? String ?: continue
                if (src.isEmpty()) continue

                val imageFile = File(src)
                if (!imageFile.exists()) continue

                // Decode image
                val sourceBitmap = decodeBitmapWithGainmap(imageFile.absolutePath) ?: continue

                val frameAspectRatio = element["aspectRatio"] as? Double ?: (sourceBitmap.width.toDouble() / sourceBitmap.height.toDouble())

                val elementWidth = (element["width"] as? Number)?.toDouble() ?: 0.0
                val elementHeight = (element["height"] as? Number)?.toDouble() ?: 0.0
                val elementX = (element["x"] as? Number)?.toDouble() ?: 0.0
                val elementY = (element["y"] as? Number)?.toDouble() ?: 0.0

                val targetWidth = (elementWidth * exportWidth).roundToInt().coerceIn(1, 20000)
                val targetHeight = (targetWidth / frameAspectRatio).roundToInt().coerceIn(1, 20000)

                val targetX = (elementX * exportWidth).roundToInt() + ((sourcePageIndex - targetPageIndex) * exportWidth)
                val targetY = (elementY * exportHeight).roundToInt()

                val cropOffsetX = (element["cropOffsetX"] as? Number)?.toDouble() ?: 0.0
                val cropOffsetY = (element["cropOffsetY"] as? Number)?.toDouble() ?: 0.0
                val cropScale = (element["cropScale"] as? Number)?.toDouble() ?: 1.0

                // Calculate source crop rect
                val cropRect = sourceCropRectForFrame(
                    sourceBitmap.width,
                    sourceBitmap.height,
                    frameAspectRatio,
                    cropOffsetX,
                    cropOffsetY,
                    cropScale
                )

                val srcRect = Rect(
                    cropRect.x,
                    cropRect.y,
                    cropRect.x + cropRect.width,
                    cropRect.y + cropRect.height
                )

                val dstRect = Rect(
                    targetX,
                    targetY,
                    targetX + targetWidth,
                    targetY + targetHeight
                )

                val borderRadiusRatio = (element["borderRadiusRatio"] as? Number)?.toDouble() ?: 0.0

                // Draw to base canvas
                if (borderRadiusRatio > 0.0) {
                    baseCanvas.save()
                    val radius = (borderRadiusRatio * minOf(targetWidth, targetHeight)).toFloat()
                    val path = android.graphics.Path().apply {
                        addRoundRect(
                            targetX.toFloat(),
                            targetY.toFloat(),
                            (targetX + targetWidth).toFloat(),
                            (targetY + targetHeight).toFloat(),
                            radius,
                            radius,
                            android.graphics.Path.Direction.CW
                        )
                    }
                    baseCanvas.clipPath(path)
                }

                baseCanvas.drawBitmap(sourceBitmap, srcRect, dstRect, paint)

                if (borderRadiusRatio > 0.0) {
                    baseCanvas.restore()
                }

                // Check gainmap
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    if (sourceBitmap.hasGainmap()) {
                        val gainmap = sourceBitmap.gainmap
                        val gainmapContents = gainmap?.gainmapContents
                        if (gainmapContents != null) {
                            if (finalGainmapBitmap == null) {
                                finalGainmapBitmap = Bitmap.createBitmap(exportWidth, exportHeight, Bitmap.Config.ARGB_8888)
                                finalGainmapCanvas = Canvas(finalGainmapBitmap!!)
                                finalGainmapCanvas!!.drawColor(0xFF000000.toInt()) // Start with black (SDR)
                                copiedGainmapParams = gainmap
                            }

                            // Map crop rect coordinates to gainmap contents size
                            val scaleX = gainmapContents.width.toFloat() / sourceBitmap.width.toFloat()
                            val scaleY = gainmapContents.height.toFloat() / sourceBitmap.height.toFloat()

                            val gSrcRect = Rect(
                                (srcRect.left * scaleX).roundToInt(),
                                (srcRect.top * scaleY).roundToInt(),
                                (srcRect.right * scaleX).roundToInt(),
                                (srcRect.bottom * scaleY).roundToInt()
                            )

                            // Draw gainmap to final gainmap canvas
                            if (borderRadiusRatio > 0.0) {
                                finalGainmapCanvas!!.save()
                                val radius = (borderRadiusRatio * minOf(targetWidth, targetHeight)).toFloat()
                                val path = android.graphics.Path().apply {
                                    addRoundRect(
                                        targetX.toFloat(),
                                        targetY.toFloat(),
                                        (targetX + targetWidth).toFloat(),
                                        (targetY + targetHeight).toFloat(),
                                        radius,
                                        radius,
                                        android.graphics.Path.Direction.CW
                                    )
                                }
                                finalGainmapCanvas!!.clipPath(path)
                            }

                            finalGainmapCanvas!!.drawBitmap(gainmapContents, gSrcRect, dstRect, paint)

                            if (borderRadiusRatio > 0.0) {
                                finalGainmapCanvas!!.restore()
                            }
                        }
                    }
                }

                sourceBitmap.recycle()
            }
        }

        // Set gainmap on base bitmap if available
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && finalGainmapBitmap != null && copiedGainmapParams != null) {
            val newGainmap = Gainmap(finalGainmapBitmap)
            // Copy parameters
            newGainmap.setRatioMin(copiedGainmapParams.ratioMin[0], copiedGainmapParams.ratioMin[1], copiedGainmapParams.ratioMin[2])
            newGainmap.setRatioMax(copiedGainmapParams.ratioMax[0], copiedGainmapParams.ratioMax[1], copiedGainmapParams.ratioMax[2])
            newGainmap.setGamma(copiedGainmapParams.gamma[0], copiedGainmapParams.gamma[1], copiedGainmapParams.gamma[2])
            newGainmap.setEpsilonSdr(copiedGainmapParams.epsilonSdr[0], copiedGainmapParams.epsilonSdr[1], copiedGainmapParams.epsilonSdr[2])
            newGainmap.setEpsilonHdr(copiedGainmapParams.epsilonHdr[0], copiedGainmapParams.epsilonHdr[1], copiedGainmapParams.epsilonHdr[2])
            newGainmap.displayRatioForFullHdr = copiedGainmapParams.displayRatioForFullHdr
            newGainmap.minDisplayRatioForHdrTransition = copiedGainmapParams.minDisplayRatioForHdrTransition

            baseBitmap.gainmap = newGainmap
        }

        val outputStream = ByteArrayOutputStream()
        baseBitmap.compress(Bitmap.CompressFormat.JPEG, 100, outputStream)
        val result = outputStream.toByteArray()

        baseBitmap.recycle()
        finalGainmapBitmap?.recycle()

        return result
    }

    private data class CropRect(val x: Int, val y: Int, val width: Int, val height: Int)

    private fun sourceCropRectForFrame(
        sourceWidth: Int,
        sourceHeight: Int,
        frameAspectRatio: Double,
        cropOffsetX: Double,
        cropOffsetY: Double,
        cropScale: Double
    ): CropRect {
        val safeFrameAspectRatio = if (frameAspectRatio <= 0) 1.0 else frameAspectRatio
        val sourceAspectRatio = sourceWidth.toDouble() / sourceHeight.toDouble()
        val safeScale = if (cropScale < 1.0) 1.0 else cropScale
        val frameHeight = 1.0
        val frameWidth = safeFrameAspectRatio
        var imageWidth = frameWidth
        var imageHeight = frameHeight

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
            0.0
        )
        val top = clampCropImageOffset(
            ((frameHeight - imageHeight) / 2) + (cropOffsetY * frameHeight),
            frameHeight - imageHeight,
            0.0
        )

        val x = ((-left / imageWidth) * sourceWidth).roundToInt().coerceIn(0, sourceWidth - 1)
        val y = ((-top / imageHeight) * sourceHeight).roundToInt().coerceIn(0, sourceHeight - 1)

        val width = ((frameWidth / imageWidth) * sourceWidth).roundToInt().coerceIn(1, sourceWidth - x)
        val height = ((frameHeight / imageHeight) * sourceHeight).roundToInt().coerceIn(1, sourceHeight - y)

        return CropRect(x, y, width, height)
    }

    private fun clampCropImageOffset(value: Double, min: Double, max: Double): Double {
        if (min >= max) return 0.0
        return value.coerceIn(min, max)
    }
}

class HdrImageView(context: Context, creationParams: Map<String, Any?>?) : PlatformView {
    private val imageView = ImageView(context)

    init {
        val path = creationParams?.get("path") as? String
        if (path != null) {
            val bitmap = decodeBitmapWithGainmap(path)
            if (bitmap != null) {
                imageView.setImageBitmap(bitmap)
            }
            val fit = creationParams["fit"] as? String
            if (fit == "contain") {
                imageView.scaleType = ImageView.ScaleType.FIT_CENTER
            } else {
                imageView.scaleType = ImageView.ScaleType.FIT_XY
            }
        }
    }

    override fun getView(): View {
        return imageView
    }

    override fun dispose() {}
}

class HdrImageViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<String, Any?>
        return HdrImageView(context, creationParams)
    }
}

private fun decodeBitmapWithGainmap(path: String): Bitmap? {
    val file = File(path)
    if (!file.exists()) return null

    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        try {
            val source = ImageDecoder.createSource(file)
            ImageDecoder.decodeBitmap(source) { decoder, _, _ ->
                decoder.isMutableRequired = true
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } catch (e: Exception) {
            BitmapFactory.decodeFile(path)
        }
    } else {
        BitmapFactory.decodeFile(path)
    }
}
