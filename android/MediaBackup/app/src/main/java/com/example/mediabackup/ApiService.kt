package com.example.mediabackup

import android.content.Context
import android.net.Uri
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.TimeUnit

class ApiService(private val context: Context) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .build()

    fun resolveBaseURL(localURL: String, tailscaleURL: String, apiKey: String): String? {
        for (raw in listOf(localURL, tailscaleURL)) {
            val base = normalizeURL(raw) ?: continue
            if (ping(base, apiKey)) return base
        }
        return null
    }

    fun ping(baseURL: String, apiKey: String): Boolean {
        return try {
            val request = Request.Builder()
                .url("$baseURL/status")
                .header("Authorization", "Bearer $apiKey")
                .build()
            client.newCall(request).execute().use { it.isSuccessful }
        } catch (_: IOException) { false }
    }

    fun uploadFile(baseURL: String, apiKey: String, file: MediaFile): Boolean {
        val dateTaken = if (file.dateTaken > 0) {
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
                .also { it.timeZone = TimeZone.getDefault() }
                .format(Date(file.dateTaken))
        } else ""

        val inputStream = context.contentResolver.openInputStream(file.uri) ?: return false
        val bytes = inputStream.use { it.readBytes() }

        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("file", file.filename,
                bytes.toRequestBody(file.mimeType.toMediaType()))
            .addFormDataPart("filename", file.filename)
            .addFormDataPart("taken_at", dateTaken)
            .addFormDataPart("device_name", android.os.Build.MODEL)
            .build()

        val request = Request.Builder()
            .url("$baseURL/upload")
            .header("Authorization", "Bearer $apiKey")
            .post(body)
            .build()

        return try {
            client.newCall(request).execute().use { it.isSuccessful }
        } catch (_: IOException) { false }
    }

    fun getStatus(baseURL: String, apiKey: String): String? {
        return try {
            val request = Request.Builder()
                .url("$baseURL/status")
                .header("Authorization", "Bearer $apiKey")
                .build()
            client.newCall(request).execute().use { resp ->
                if (resp.isSuccessful) resp.body?.string() else null
            }
        } catch (_: IOException) { null }
    }

    private fun normalizeURL(raw: String): String? {
        var s = raw.trim()
        if (s.isEmpty()) return null
        if (!s.startsWith("http")) s = "http://$s"
        if (s.endsWith("/")) s = s.dropLast(1)
        return s
    }
}
