package com.igapp.igapp

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import com.igapp.igapp.hdr.HdrImageViewFactory
import com.igapp.igapp.hdr.NativePageRenderer
import com.igapp.igapp.hdr.UltraHdrSupport
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val pendingSharedImagePaths = mutableListOf<String>()
    private var shareChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The HDR window color mode must be in place before the first frame, so
        // read the Flutter-side setting directly from its SharedPreferences file.
        val hdrEnabled =
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.settings_hdr_enabled", true)
        if (hdrEnabled) {
            UltraHdrSupport.setWindowHdrColorMode(this, true)
        }
        queueSharedImagesFromIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "igapp/hdr_image_view",
            HdrImageViewFactory(),
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

                    result.success(ImageAssetStore.saveJpgToGallery(applicationContext, bytes, name))
                }
                "saveOriginalToGallery" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")

                    if (path.isNullOrBlank() || name.isNullOrBlank()) {
                        result.error("invalid_args", "Missing source path or name.", null)
                        return@setMethodCallHandler
                    }

                    ioExecutor.execute {
                        val saved =
                            try {
                                ImageAssetStore.saveOriginalToGallery(applicationContext, path, name)
                            } catch (_: Exception) {
                                false
                            }
                        runOnUiThread { result.success(saved) }
                    }
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
                            val prepared =
                                ImageAssetStore.prepareImageAsset(
                                    applicationContext,
                                    sourcePath,
                                    projectId,
                                    maxPreviewSide,
                                )
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
                            val bytes = ImageAssetStore.readImageBytesForExport(path)
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
                    @Suppress("UNCHECKED_CAST")
                    val payload = call.arguments as? Map<String, Any>
                    if (payload == null) {
                        result.error("invalid_args", "Missing payload map.", null)
                        return@setMethodCallHandler
                    }

                    ioExecutor.execute {
                        try {
                            val bytes = NativePageRenderer.render(payload)
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "igapp/hdr",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCapabilities" -> result.success(UltraHdrSupport.capabilities(this))
                "setHdrColorMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    result.success(UltraHdrSupport.setWindowHdrColorMode(this, enabled))
                }
                "inspectImage" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_args", "Missing image path.", null)
                        return@setMethodCallHandler
                    }
                    ioExecutor.execute {
                        val info =
                            try {
                                UltraHdrSupport.inspectImage(path)
                            } catch (exception: Exception) {
                                mapOf<String, Any>(
                                    "exists" to false,
                                    "isUltraHdr" to false,
                                    "error" to (exception.message ?: "inspect failed"),
                                )
                            }
                        runOnUiThread { result.success(info) }
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
}
