package com.example.mediabackup

import android.content.Context
import android.content.SharedPreferences
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class UploadWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    private val prefs: SharedPreferences =
        appContext.getSharedPreferences("uploaded_ids", Context.MODE_PRIVATE)

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val app      = applicationContext as MediaBackupApp
        val settings = app.settingsManager
        val api      = ApiService(applicationContext)

        val localURL     = settings.localURL.value
        val tailscaleURL = settings.tailscaleURL.value
        val apiKey       = settings.apiKey.value

        if (apiKey.isBlank() || (localURL.isBlank() && tailscaleURL.isBlank())) {
            return@withContext Result.success()   // not configured yet
        }

        val baseURL = api.resolveBaseURL(localURL, tailscaleURL, apiKey)
            ?: return@withContext Result.retry()  // no connectivity, retry later

        val uploadedIds = prefs.getStringSet("ids", emptySet())!!
            .mapNotNull { it.toLongOrNull() }.toMutableSet()

        val pending = MediaScanner.scanNewFiles(applicationContext, uploadedIds)
        if (pending.isEmpty()) return@withContext Result.success()

        var failed = 0
        for (file in pending) {
            val ok = api.uploadFile(baseURL, apiKey, file)
            if (ok) {
                uploadedIds.add(file.id)
                prefs.edit().putStringSet("ids", uploadedIds.map { it.toString() }.toSet()).apply()
            } else {
                failed++
            }
        }

        if (failed > 0 && failed == pending.size) Result.retry() else Result.success()
    }
}
