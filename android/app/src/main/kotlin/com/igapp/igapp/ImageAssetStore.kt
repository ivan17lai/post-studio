package com.igapp.igapp

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.igapp.igapp.hdr.UltraHdrSupport
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest

/**
 * Disk/MediaStore plumbing for imported and exported images.
 *
 * Imported originals are copied verbatim into the project's `originals/`
 * directory and are never re-encoded — previews in `previews/` are derived
 * caches only. Exports either receive freshly rendered JPEG bytes
 * ([saveJpgToGallery]) or, for the lossless passthrough path, a byte-for-byte
 * copy of the original file ([saveOriginalToGallery]).
 */
object ImageAssetStore {
    fun prepareImageAsset(
        context: Context,
        sourcePath: String,
        projectId: String,
        maxPreviewSide: Int,
    ): Map<String, Any> {
        val sourceFile = File(sourcePath)
        require(sourceFile.exists()) { "Source image does not exist." }

        val originalsDir =
            File(
                context.filesDir,
                "project_images${File.separator}$projectId${File.separator}originals",
            ).apply { mkdirs() }
        val previewsDir =
            File(
                context.filesDir,
                "project_images${File.separator}$projectId${File.separator}previews",
            ).apply { mkdirs() }

        val extension = sourceFile.extension.lowercase().ifBlank { "jpg" }
        val hashedName = sha256OfFile(sourceFile)
        val originalFile = File(originalsDir, "$hashedName.$extension")
        if (sourceFile.absolutePath != originalFile.absolutePath && !originalFile.exists()) {
            sourceFile.copyTo(originalFile, overwrite = false)
        }

        val isUltraHdr =
            UltraHdrSupport.supportsGainmap && UltraHdrSupport.fileLooksUltraHdr(originalFile)

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
                "isUltraHdr" to isUltraHdr,
            )
        }

        val resizedBitmap =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                try {
                    val source = ImageDecoder.createSource(originalFile)
                    ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                        decoder.isMutableRequired = true
                        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                        val scale =
                            maxPreviewSide.toFloat() / maxOf(info.size.width, info.size.height)
                        if (scale < 1.0f) {
                            decoder.setTargetSize(
                                (info.size.width * scale).toInt().coerceAtLeast(1),
                                (info.size.height * scale).toInt().coerceAtLeast(1),
                            )
                        }
                    }
                } catch (_: Exception) {
                    decodeAndScaleLegacy(
                        originalFile.absolutePath,
                        sourceWidth,
                        sourceHeight,
                        maxPreviewSide,
                    )
                }
            } else {
                decodeAndScaleLegacy(
                    originalFile.absolutePath,
                    sourceWidth,
                    sourceHeight,
                    maxPreviewSide,
                )
            }

        val previewExtension = if (extension == "png") "png" else "jpg"
        val previewFile = File(previewsDir, "$hashedName.$previewExtension")
        FileOutputStream(previewFile).use { output ->
            val format =
                if (previewExtension == "png") {
                    Bitmap.CompressFormat.PNG
                } else {
                    // On API 34+ the JPEG encoder keeps the (scaled) gain map, so
                    // the preview file stays Ultra HDR for the in-app HDR viewer.
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
            "isUltraHdr" to isUltraHdr,
        )
    }

    fun readImageBytesForExport(path: String): ByteArray {
        val file = File(path)
        require(file.exists()) { "Image does not exist." }
        return file.readBytes()
    }

    fun saveJpgToGallery(context: Context, bytes: ByteArray, name: String): Boolean {
        return saveStreamToGallery(context, "$name.jpg", "image/jpeg") { output ->
            output.write(bytes)
        }
    }

    /**
     * Lossless passthrough export: copies the original file into the gallery
     * byte-for-byte (gain map, EXIF and ICC data all survive untouched).
     */
    fun saveOriginalToGallery(context: Context, path: String, name: String): Boolean {
        val file = File(path)
        if (!file.exists()) {
            return false
        }
        val extension = file.extension.lowercase().ifBlank { "jpg" }
        val mimeType =
            when (extension) {
                "png" -> "image/png"
                "webp" -> "image/webp"
                "heic", "heif" -> "image/heic"
                "gif" -> "image/gif"
                "bmp" -> "image/bmp"
                else -> "image/jpeg"
            }
        return saveStreamToGallery(context, "$name.$extension", mimeType) { output ->
            FileInputStream(file).use { input -> input.copyTo(output) }
        }
    }

    private fun saveStreamToGallery(
        context: Context,
        displayName: String,
        mimeType: String,
        writeBody: (java.io.OutputStream) -> Unit,
    ): Boolean {
        val resolver = context.contentResolver
        val values =
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Images.Media.MIME_TYPE, mimeType)
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
                writeBody(stream)
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

    private fun computeInSampleSize(width: Int, height: Int, maxPreviewSide: Int): Int {
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

    private fun decodeAndScaleLegacy(
        path: String,
        width: Int,
        height: Int,
        maxPreviewSide: Int,
    ): Bitmap {
        val sampleSize = computeInSampleSize(width, height, maxPreviewSide)
        val decodeOptions =
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
        val decoded =
            BitmapFactory.decodeFile(path, decodeOptions) ?: error("Failed to decode image")
        return if (maxOf(decoded.width, decoded.height) <= maxPreviewSide) {
            decoded
        } else {
            val scale = maxPreviewSide.toFloat() / maxOf(decoded.width, decoded.height)
            val newWidth = (decoded.width * scale).toInt().coerceAtLeast(1)
            val newHeight = (decoded.height * scale).toInt().coerceAtLeast(1)
            Bitmap.createScaledBitmap(decoded, newWidth, newHeight, true).also {
                if (it != decoded) {
                    decoded.recycle()
                }
            }
        }
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
}
