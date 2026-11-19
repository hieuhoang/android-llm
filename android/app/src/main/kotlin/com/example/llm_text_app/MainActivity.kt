package com.example.llm_text_app

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.system.Os
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val modelDescriptors = mutableMapOf<String, ParcelFileDescriptor>()
    private val verificationGeneration = AtomicInteger()
    private val preferences by lazy { getSharedPreferences("model_download", Context.MODE_PRIVATE) }
    private val downloads by lazy { getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "llm_text_app/build_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "buildTimestamp" -> result.success(BuildConfig.BUILD_TIMESTAMP)
                    "keepScreenOn" -> {
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "llm_text_app/model_download")
            .setMethodCallHandler { call, result ->
                try {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        throw UnsupportedOperationException("Public model downloads require Android 10 or later.")
                    }
                    val key = call.argument<String>("key")
                    when (call.method) {
                        "start" -> result.success(startDownload(requireNotNull(key)))
                        "status" -> result.success(downloadStatus(requireNotNull(key)))
                        "open" -> {
                            val name = requireNotNull(key)
                            modelDescriptors.remove(name)?.close()
                            val descriptor = downloads.openDownloadedFile(downloadId(name))
                            modelDescriptors[name] = descriptor
                            result.success(descriptor.fd)
                        }
                        "verify" -> {
                            val name = requireNotNull(key)
                            val expected = requireNotNull(call.argument<String>("checksum"))
                            val id = downloadId(name)
                            val descriptor = requireNotNull(modelDescriptors[name]) { "Model file is not open: $name" }
                            val path = "/proc/self/fd/${descriptor.fd}"
                            val generation = verificationGeneration.incrementAndGet()
                            thread(name = "model-checksum") {
                                try {
                                    val checksum = FileInputStream(path).use { input ->
                                        fun identity(): String {
                                            val stat = Os.fstat(input.fd)
                                            return "$id:$expected:${stat.st_dev}:${stat.st_ino}:${stat.st_size}:" +
                                                "${stat.st_mtim.tv_sec}:${stat.st_mtim.tv_nsec}:" +
                                                "${stat.st_ctim.tv_sec}:${stat.st_ctim.tv_nsec}"
                                        }
                                        val cacheKey = "verified_$name"
                                        var initialIdentity = identity()
                                        check(generation == verificationGeneration.get()) { "Model verification stopped." }
                                        if (preferences.getString(cacheKey, null) == initialIdentity) {
                                            Log.i("ModelVerification", "Reusing verified download: $name")
                                            expected
                                        } else {
                                            check(preferences.edit().remove(cacheKey).commit()) { "Could not clear model verification." }
                                            Log.i("ModelVerification", "Verifying download: $name")
                                            for (attempt in 0..1) {
                                                val digest = MessageDigest.getInstance("SHA-256")
                                                val buffer = ByteArray(256 * 1024)
                                                while (true) {
                                                    check(generation == verificationGeneration.get()) { "Model verification stopped." }
                                                    val count = input.read(buffer)
                                                    if (count < 0) break
                                                    digest.update(buffer, 0, count)
                                                }
                                                check(generation == verificationGeneration.get()) { "Model verification stopped." }
                                                val finalIdentity = identity()
                                                if (finalIdentity != initialIdentity) {
                                                    check(attempt == 0) { "Model file changed during verification: $name." }
                                                    Log.i("ModelVerification", "File changed; retrying verification: $name")
                                                    initialIdentity = finalIdentity
                                                    input.channel.position(0)
                                                    continue
                                                }
                                                val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                                                check(actual == expected) { "Checksum mismatch for $name." }
                                                check(preferences.edit().putString(cacheKey, initialIdentity).commit()) {
                                                    "Could not save model verification."
                                                }
                                                Log.i("ModelVerification", "Verified download: $name")
                                                return@use actual
                                            }
                                            error("Model verification did not complete: $name.")
                                        }
                                    }
                                    runOnUiThread { result.success(checksum) }
                                } catch (error: Exception) {
                                    runOnUiThread { result.error("model_verification", error.message, null) }
                                }
                            }
                        }
                        "cancelVerification" -> {
                            verificationGeneration.incrementAndGet()
                            result.success(null)
                        }
                        "cancel" -> {
                            val name = requireNotNull(key)
                            val id = preferences.getLong(preferenceKey(name), -1)
                            if (id != -1L && downloadStatus(name)?.get("status") != DownloadManager.STATUS_SUCCESSFUL) {
                                downloads.remove(id)
                                preferences.edit().remove(preferenceKey(name)).apply()
                            }
                            result.success(null)
                        }
                        "close" -> {
                            closeDescriptors()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("model_download", error.message, null)
                }
            }
    }

    private fun preferenceKey(key: String) = if (key == "qwen3") "id" else "id_$key"

    private fun downloadId(key: String): Long {
        val id = preferences.getLong(preferenceKey(key), -1)
        check(id != -1L) { "No model download is available." }
        return id
    }

    private fun startDownload(key: String): Long {
        val (repo, revision, filename) = when (key) {
            "qwen3" -> Triple("Qwen/Qwen3-0.6B-GGUF", "23749fefcc72300e3a2ad315e1317431b06b590a", "Qwen3-0.6B-Q8_0.gguf")
            "omni_q2" -> Triple("unsloth/Qwen2.5-Omni-3B-GGUF", "9eb5b23b5222c0ec3b81ce932e35a7f21a9b75d3", "Qwen2.5-Omni-3B-Q2_K.gguf")
            "omni" -> Triple("ggml-org/Qwen2.5-Omni-3B-GGUF", "75f1b73b657a50f5092502799457ccb4a4a1f9df", "Qwen2.5-Omni-3B-Q4_K_M.gguf")
            "omni_q8" -> Triple("ggml-org/Qwen2.5-Omni-3B-GGUF", "75f1b73b657a50f5092502799457ccb4a4a1f9df", "Qwen2.5-Omni-3B-Q8_0.gguf")
            "omni_projector" -> Triple("ggml-org/Qwen2.5-Omni-3B-GGUF", "75f1b73b657a50f5092502799457ccb4a4a1f9df", "mmproj-Qwen2.5-Omni-3B-Q8_0.gguf")
            else -> throw IllegalArgumentException("Unknown model file: $key")
        }
        val prefKey = preferenceKey(key)
        val existing = preferences.getLong(prefKey, -1)
        if (existing != -1L) {
            val status = downloadStatus(key)
            if (status != null && status["status"] != DownloadManager.STATUS_FAILED) return existing
            if (status != null) downloads.remove(existing)
            preferences.edit().remove(prefKey).apply()
        }
        val url = "https://huggingface.co/$repo/resolve/$revision/$filename"
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(filename)
            .setDescription("Downloading the on-device language model")
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, filename)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        val id = downloads.enqueue(request)
        preferences.edit().putLong(prefKey, id).apply()
        return id
    }

    private fun downloadStatus(key: String): Map<String, Any>? {
        val cursor = downloads.query(DownloadManager.Query().setFilterById(downloadId(key)))
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

    private fun closeDescriptors() {
        verificationGeneration.incrementAndGet()
        modelDescriptors.values.forEach { it.close() }
        modelDescriptors.clear()
    }

    override fun onDestroy() {
        closeDescriptors()
        super.onDestroy()
    }
}
