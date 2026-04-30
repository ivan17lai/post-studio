package com.igapp.igapp

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Gainmap
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
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
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val pendingSharedImagePaths = mutableListOf<String>()
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        queueSharedImagesFromIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "igapp/gallery",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setUltraHdrMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setUltraHdrMode(enabled)
                    result.success(true)
                }
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
                "renderUltraHdrPageForExport" -> {
                    val payload = call.arguments as? Map<*, *>
                    if (payload == null) {
                        result.error("invalid_args", "Missing export payload.", null)
                        return@setMethodCallHandler
                    }

                    ioExecutor.execute {
                        try {
                            val bytes = renderUltraHdrPageForExport(payload)
                            runOnUiThread { result.success(bytes) }
                        } catch (exception: Exception) {
                            runOnUiThread {
                                result.error(
                                    "render_ultra_hdr_failed",
                                    exception.message ?: "renderUltraHdrPageForExport failed",
                                    null,
                                )
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        flutterEngine
            .platformViewsController
            .registry
            .registerViewFactory(
                "igapp/ultra_hdr_image",
                UltraHdrImageViewFactory(this),
            )

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

    private fun setUltraHdrMode(enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            window.colorMode =
                if (enabled) {
                    ActivityInfo.COLOR_MODE_HDR
                } else {
                    ActivityInfo.COLOR_MODE_DEFAULT
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
        val hashedName =
            "${System.currentTimeMillis()}_${sourceFile.nameWithoutExtension.hashCode().toUInt()}"
        val originalFile = File(originalsDir, "$hashedName.$extension")
        if (sourceFile.absolutePath != originalFile.absolutePath) {
            sourceFile.copyTo(originalFile, overwrite = true)
        }
        val wasUltraHdr = looksLikeUltraHdrJpeg(originalFile)

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
                "wasUltraHdr" to wasUltraHdr,
                "width" to sourceWidth.toDouble(),
                "height" to sourceHeight.toDouble(),
            )
        }

        val sampleSize = computeInSampleSize(sourceWidth, sourceHeight, maxPreviewSide)
        val decodeOptions =
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
        val decodedBitmap =
            BitmapFactory.decodeFile(originalFile.absolutePath, decodeOptions)
                ?: error("Failed to decode source image.")

        val resizedBitmap =
            if (maxOf(decodedBitmap.width, decodedBitmap.height) <= maxPreviewSide) {
                decodedBitmap
            } else {
                val scale = maxPreviewSide.toFloat() / maxOf(decodedBitmap.width, decodedBitmap.height)
                Bitmap.createScaledBitmap(
                    decodedBitmap,
                    (decodedBitmap.width * scale).toInt().coerceAtLeast(1),
                    (decodedBitmap.height * scale).toInt().coerceAtLeast(1),
                    true,
                ).also {
                    if (it != decodedBitmap) {
                        decodedBitmap.recycle()
                    }
                }
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
        val previewWasUltraHdr = wasUltraHdr || bitmapHasGainmap(resizedBitmap)
        resizedBitmap.recycle()

        return mapOf(
            "displayPath" to previewFile.absolutePath,
            "originalPath" to originalFile.absolutePath,
            "wasUltraHdr" to previewWasUltraHdr,
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

    private fun readImageBytesForExport(path: String): ByteArray {
        val file = File(path)
        require(file.exists()) { "Image does not exist." }

        return file.readBytes()
    }

    private fun looksLikeUltraHdrJpeg(file: File): Boolean {
        if (!file.exists() || !isJpegLike(file)) {
            return false
        }

        val headerBytes = ByteArray(minOf(file.length(), 512L * 1024L).toInt())
        val bytesRead =
            file.inputStream().use { input ->
                input.read(headerBytes)
            }
        if (bytesRead <= 0) {
            return false
        }

        val headerText =
            String(headerBytes, 0, bytesRead, StandardCharsets.ISO_8859_1)
        return headerText.contains("hdrgm:Version") ||
            headerText.contains("http://ns.adobe.com/hdr-gain-map/1.0/") ||
            headerText.contains("GainMap")
    }

    private fun isJpegLike(file: File): Boolean {
        val extension = file.extension.lowercase()
        if (extension == "jpg" || extension == "jpeg") {
            return true
        }

        return try {
            file.inputStream().use { input ->
                input.read() == 0xFF && input.read() == 0xD8
            }
        } catch (_: IOException) {
            false
        }
    }

    private data class NativeExportPage(
        val aspectWidth: Double,
        val aspectHeight: Double,
        val backgroundColor: Int,
        val originalIndex: Int,
        val elements: List<NativeExportElement>,
    )

    private data class NativeExportElement(
        val type: String,
        val x: Double,
        val y: Double,
        val width: Double,
        val height: Double,
        val allowCrossPage: Boolean,
        val src: String,
        val aspectRatio: Double?,
    )

    private fun renderUltraHdrPageForExport(payload: Map<*, *>): ByteArray {
        val exportWidth = numberToInt(payload["exportWidth"], 1080).coerceAtLeast(1)
        val targetPageIndex = numberToInt(payload["targetPageIndex"], 0)
        val pages = parseNativeExportPages(payload["pages"])
        require(targetPageIndex in pages.indices) { "Invalid target page index." }

        val targetPage = pages[targetPageIndex]
        val exportHeight =
            (exportWidth * (targetPage.aspectHeight / targetPage.aspectWidth))
                .roundToInt()
                .coerceAtLeast(1)
        val targetOriginalIndex = targetPage.originalIndex
        val outputBitmap =
            Bitmap.createBitmap(exportWidth, exportHeight, Bitmap.Config.ARGB_8888)
        val outputCanvas = Canvas(outputBitmap)
        outputCanvas.drawColor(targetPage.backgroundColor)

        val paint =
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG)
        var outputGainmapBitmap: Bitmap? = null
        var outputGainmapCanvas: Canvas? = null
        var gainmapTemplate: Gainmap? = null
        val neutralGainmapPaint =
            Paint().apply {
                color = Color.rgb(128, 128, 128)
                style = Paint.Style.FILL
            }

        for (sourcePageIndex in pages.indices) {
            val sourcePage = pages[sourcePageIndex]
            val sourceOriginalIndex = sourcePage.originalIndex

            for (element in sourcePage.elements) {
                if (element.type != "image" || element.src.isBlank() || element.width <= 0) {
                    continue
                }

                if (sourcePageIndex != targetPageIndex) {
                    if (!element.allowCrossPage) {
                        continue
                    }
                    val elementAspectRatio = element.aspectRatio
                    val elementHeight =
                        if (elementAspectRatio != null && elementAspectRatio > 0) {
                            element.width / elementAspectRatio
                        } else {
                            element.height
                        }
                    val left = (sourceOriginalIndex - targetOriginalIndex) + element.x
                    val right = left + element.width
                    val top = element.y
                    val bottom = top + elementHeight
                    if (right <= 0 || left >= 1 || bottom <= 0 || top >= 1) {
                        continue
                    }
                }

                val sourceBitmap = decodeBitmap(File(element.src)) ?: continue
                try {
                    val frameAspectRatio =
                        element.aspectRatio ?: (sourceBitmap.width.toDouble() / sourceBitmap.height)
                    val targetWidth =
                        (element.width * exportWidth).roundToInt().coerceIn(1, 20000)
                    val targetHeight =
                        (targetWidth / frameAspectRatio).roundToInt().coerceIn(1, 20000)
                    val targetX =
                        (element.x * exportWidth).roundToInt() +
                            ((sourceOriginalIndex - targetOriginalIndex) * exportWidth)
                    val targetY = (element.y * exportHeight).roundToInt()
                    val destRect =
                        RectF(
                            targetX.toFloat(),
                            targetY.toFloat(),
                            (targetX + targetWidth).toFloat(),
                            (targetY + targetHeight).toFloat(),
                        )
                    val sourceRect =
                        coverSourceRect(
                            sourceBitmap.width,
                            sourceBitmap.height,
                            frameAspectRatio,
                        )

                    outputCanvas.drawBitmap(sourceBitmap, sourceRect, destRect, paint)

                    if (Build.VERSION.SDK_INT >= 34) {
                        val sourceGainmap = sourceBitmap.gainmap
                        if (sourceGainmap != null) {
                            if (outputGainmapBitmap == null) {
                                outputGainmapBitmap =
                                    Bitmap.createBitmap(
                                        exportWidth,
                                        exportHeight,
                                        Bitmap.Config.ARGB_8888,
                                    )
                                outputGainmapCanvas = Canvas(outputGainmapBitmap!!)
                                outputGainmapCanvas!!.drawColor(Color.rgb(128, 128, 128))
                            }
                            if (gainmapTemplate == null) {
                                gainmapTemplate = sourceGainmap
                            }

                            val gainmapContents = sourceGainmap.gainmapContents
                            outputGainmapCanvas?.drawBitmap(
                                gainmapContents,
                                mapSourceRectToGainmap(
                                    sourceRect,
                                    sourceBitmap,
                                    gainmapContents,
                                ),
                                destRect,
                                paint,
                            )
                        } else {
                            outputGainmapCanvas?.drawRect(destRect, neutralGainmapPaint)
                        }
                    }
                } finally {
                    sourceBitmap.recycle()
                }
            }
        }

        if (Build.VERSION.SDK_INT >= 34 && outputGainmapBitmap != null) {
            val outputGainmap =
                gainmapTemplate?.let { template ->
                    Gainmap(outputGainmapBitmap!!).also {
                        copyGainmapMetadata(template, it)
                    }
                } ?: Gainmap(outputGainmapBitmap!!)
            outputBitmap.setGainmap(outputGainmap)
        }

        return ByteArrayOutputStream().use { output ->
            outputBitmap.compress(Bitmap.CompressFormat.JPEG, 100, output)
            outputBitmap.recycle()
            outputGainmapBitmap?.recycle()
            output.toByteArray()
        }
    }

    private fun parseNativeExportPages(rawPages: Any?): List<NativeExportPage> {
        val pages = rawPages as? List<*> ?: emptyList<Any>()
        return pages.mapIndexed { pageIndex, rawPage ->
            val page = rawPage as? Map<*, *> ?: emptyMap<Any, Any>()
            val elements =
                (page["elements"] as? List<*> ?: emptyList<Any>()).mapNotNull { rawElement ->
                    val element = rawElement as? Map<*, *> ?: return@mapNotNull null
                    NativeExportElement(
                        type = element["type"] as? String ?: "",
                        x = numberToDouble(element["x"], 0.0),
                        y = numberToDouble(element["y"], 0.0),
                        width = numberToDouble(element["width"], 0.0),
                        height = numberToDouble(element["height"], 0.0),
                        allowCrossPage = element["allowCrossPage"] as? Boolean ?: true,
                        src = element["src"] as? String ?: "",
                        aspectRatio = (element["aspectRatio"] as? Number)?.toDouble(),
                    )
                }
            NativeExportPage(
                aspectWidth = numberToDouble(page["aspectWidth"], 4.0),
                aspectHeight = numberToDouble(page["aspectHeight"], 5.0),
                backgroundColor = numberToInt(page["backgroundColor"], Color.WHITE),
                originalIndex = numberToInt(page["originalIndex"], pageIndex),
                elements = elements,
            )
        }
    }

    private fun coverSourceRect(
        sourceWidth: Int,
        sourceHeight: Int,
        frameAspectRatio: Double,
    ): Rect {
        val sourceAspectRatio = sourceWidth.toDouble() / sourceHeight
        return if (sourceAspectRatio > frameAspectRatio) {
            val cropWidth =
                (sourceHeight * frameAspectRatio).roundToInt().coerceIn(1, sourceWidth)
            val offsetX = ((sourceWidth - cropWidth) / 2.0).roundToInt()
            Rect(offsetX, 0, offsetX + cropWidth, sourceHeight)
        } else {
            val cropHeight =
                (sourceWidth / frameAspectRatio).roundToInt().coerceIn(1, sourceHeight)
            val offsetY = ((sourceHeight - cropHeight) / 2.0).roundToInt()
            Rect(0, offsetY, sourceWidth, offsetY + cropHeight)
        }
    }

    private fun mapSourceRectToGainmap(
        sourceRect: Rect,
        sourceBitmap: Bitmap,
        gainmapBitmap: Bitmap,
    ): Rect {
        val scaleX = gainmapBitmap.width.toDouble() / sourceBitmap.width
        val scaleY = gainmapBitmap.height.toDouble() / sourceBitmap.height
        return Rect(
            (sourceRect.left * scaleX).roundToInt().coerceIn(0, gainmapBitmap.width - 1),
            (sourceRect.top * scaleY).roundToInt().coerceIn(0, gainmapBitmap.height - 1),
            (sourceRect.right * scaleX).roundToInt().coerceIn(1, gainmapBitmap.width),
            (sourceRect.bottom * scaleY).roundToInt().coerceIn(1, gainmapBitmap.height),
        )
    }

    private fun copyGainmapMetadata(source: Gainmap, target: Gainmap) {
        val ratioMin = source.ratioMin
        target.setRatioMin(ratioMin[0], ratioMin[1], ratioMin[2])
        val ratioMax = source.ratioMax
        target.setRatioMax(ratioMax[0], ratioMax[1], ratioMax[2])
        val gamma = source.gamma
        target.setGamma(gamma[0], gamma[1], gamma[2])
        val epsilonSdr = source.epsilonSdr
        target.setEpsilonSdr(epsilonSdr[0], epsilonSdr[1], epsilonSdr[2])
        val epsilonHdr = source.epsilonHdr
        target.setEpsilonHdr(epsilonHdr[0], epsilonHdr[1], epsilonHdr[2])
        target.setMinDisplayRatioForHdrTransition(source.minDisplayRatioForHdrTransition)
        target.setDisplayRatioForFullHdr(source.displayRatioForFullHdr)
        target.setAlternativeImagePrimaries(source.alternativeImagePrimaries)
    }

    private fun decodeBitmap(file: File): Bitmap? {
        if (!file.exists()) {
            return null
        }
        return BitmapFactory.decodeFile(
            file.absolutePath,
            BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
            },
        )
    }

    private fun decodeBitmapForDisplay(
        path: String,
        targetWidth: Int,
        targetHeight: Int,
    ): Bitmap? {
        val file = File(path)
        if (!file.exists()) {
            return null
        }

        val bounds =
            BitmapFactory.Options().apply {
                inJustDecodeBounds = true
                BitmapFactory.decodeFile(file.absolutePath, this)
            }
        val sourceWidth = bounds.outWidth
        val sourceHeight = bounds.outHeight
        if (sourceWidth <= 0 || sourceHeight <= 0) {
            return null
        }
        val maxDisplaySide = maxOf(targetWidth, targetHeight, 1080)
        val sampleSize = computeInSampleSize(sourceWidth, sourceHeight, maxDisplaySide)
        return BitmapFactory.decodeFile(
            file.absolutePath,
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            },
        )
    }

    private fun bitmapHasGainmap(bitmap: Bitmap): Boolean {
        return Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap()
    }

    private fun numberToDouble(value: Any?, fallback: Double): Double {
        return (value as? Number)?.toDouble() ?: fallback
    }

    private fun numberToInt(value: Any?, fallback: Int): Int {
        return (value as? Number)?.toInt() ?: fallback
    }

    private class UltraHdrImageViewFactory(
        private val activity: MainActivity,
    ) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(
            context: Context,
            viewId: Int,
            args: Any?,
        ): PlatformView {
            val params = args as? Map<*, *> ?: emptyMap<Any, Any>()
            return UltraHdrImagePlatformView(context, activity, params)
        }
    }

    private class UltraHdrImagePlatformView(
        context: Context,
        private val activity: MainActivity,
        params: Map<*, *>,
    ) : PlatformView {
        private val imageView =
            ImageView(context).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
                setBackgroundColor(Color.TRANSPARENT)
                setLayerType(View.LAYER_TYPE_HARDWARE, null)
            }
        private var bitmap: Bitmap? = null

        init {
            val path = params["path"] as? String ?: ""
            val targetWidth = activity.numberToInt(params["targetWidth"], 1080)
            val targetHeight = activity.numberToInt(params["targetHeight"], 1080)
            bitmap = activity.decodeBitmapForDisplay(path, targetWidth, targetHeight)
            bitmap?.let {
                imageView.setImageBitmap(it)
                if (Build.VERSION.SDK_INT >= 34 && it.hasGainmap()) {
                    activity.setUltraHdrMode(true)
                }
            }
        }

        override fun getView(): View = imageView

        override fun dispose() {
            imageView.setImageDrawable(null)
            bitmap?.recycle()
            bitmap = null
        }
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
}
