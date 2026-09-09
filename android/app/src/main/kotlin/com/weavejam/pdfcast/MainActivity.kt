package com.weavejam.pdfcast

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    // 冷启动时 Flutter 还没起来，先缓存路径，等 Dart 调 getInitialPdf 取走
    private var pendingPdfPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pdfcast/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "getInitialPdf") {
                    result.success(pendingPdfPath)
                    pendingPdfPath = null
                } else {
                    result.notImplemented()
                }
            }
        }
        handleIntent(intent, coldStart = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent, coldStart = false)
    }

    private fun handleIntent(intent: Intent?, coldStart: Boolean) {
        @Suppress("DEPRECATION")
        val uri: Uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        } ?: return
        val path = copyToCache(uri) ?: return
        if (coldStart) {
            pendingPdfPath = path
        } else {
            channel?.invokeMethod("onPdf", path) ?: run { pendingPdfPath = path }
        }
    }

    // content:// 只能通过 ContentResolver 读，拷到 cache 目录换成普通文件路径给 Dart
    private fun copyToCache(uri: Uri): String? {
        return try {
            val name = queryDisplayName(uri) ?: "shared-${System.currentTimeMillis()}.pdf"
            val safe = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
                .let { if (it.lowercase().endsWith(".pdf")) it else "$it.pdf" }
            val dst = File(cacheDir, "shared").apply { mkdirs() }.resolve(safe)
            contentResolver.openInputStream(uri)?.use { input ->
                dst.outputStream().use { input.copyTo(it) }
            } ?: return null
            dst.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (_: Exception) {
            null
        }
    }
}
