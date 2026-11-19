package com.example.llm_text_app

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var modelDescriptor: ParcelFileDescriptor? = null
    private val preferences by lazy { getSharedPreferences("model_download", Context.MODE_PRIVATE) }
    private val downloads by lazy { getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "llm_text_app/model_download")
            .setMethodCallHandler { call, result ->
                try {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        throw UnsupportedOperationException("Public model downloads require Android 10 or later.")
                    }
                    when (call.method) {
                        "start" -> result.success(startDownload())
                        "status" -> result.success(downloadStatus())
                        "open" -> {
                            modelDescriptor?.close()
                            val id = downloadId()
                            modelDescriptor = downloads.openDownloadedFile(id)
                            result.success(modelDescriptor!!.fd)
                        }
                        "cancel" -> {
                            val id = preferences.getLong("id", -1)
                            if (id != -1L && downloadStatus()?.get("status") != DownloadManager.STATUS_SUCCESSFUL) {
                                downloads.remove(id)
                                preferences.edit().remove("id").apply()
                            }
                            result.success(null)
                        }
                        "close" -> {
                            modelDescriptor?.close()
                            modelDescriptor = null
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("model_download", error.message, null)
                }
            }
    }

    private fun downloadId(): Long {
        val id = preferences.getLong("id", -1)
        check(id != -1L) { "No model download is available." }
        return id
    }

    private fun startDownload(): Long {
        val existing = preferences.getLong("id", -1)
        if (existing != -1L) {
            val status = downloadStatus()
            if (status != null && status["status"] != DownloadManager.STATUS_FAILED) return existing
            if (status != null) downloads.remove(existing)
            preferences.edit().remove("id").apply()
        }
        val url = "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/" +
            "23749fefcc72300e3a2ad315e1317431b06b590a/Qwen3-0.6B-Q8_0.gguf"
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle("Qwen3 0.6B model")
            .setDescription("Downloading the on-device language model")
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, "Qwen3-0.6B-Q8_0.gguf")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        val id = downloads.enqueue(request)
        preferences.edit().putLong("id", id).apply()
        return id
    }

    private fun downloadStatus(): Map<String, Any>? {
        val cursor = downloads.query(DownloadManager.Query().setFilterById(downloadId()))
        cursor.use {
            if (it == null || !it.moveToFirst()) return null
            fun value(column: String): Long = it.getLong(it.getColumnIndexOrThrow(column))
            return mapOf(
                "status" to value(DownloadManager.COLUMN_STATUS).toInt(),
                "reason" to value(DownloadManager.COLUMN_REASON),
                "received" to value(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                "total" to value(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
            )
        }
    }

    override fun onDestroy() {
        modelDescriptor?.close()
        modelDescriptor = null
        super.onDestroy()
    }
}
