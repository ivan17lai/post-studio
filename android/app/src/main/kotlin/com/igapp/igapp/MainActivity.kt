package com.igapp.igapp

import android.content.Intent
import android.content.ContentValues
import android.net.Uri
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors

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
