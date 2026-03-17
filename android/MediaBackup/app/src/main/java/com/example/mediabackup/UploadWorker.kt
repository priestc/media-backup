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

        val localHost     = settings.localHost.value
        val tailscaleHost = settings.tailscaleHost.value
        val port          = settings.port.value.toIntOrNull() ?: 22
        val username      = settings.username.value
        val password      = settings.password.value
        val remotePath    = settings.remotePath.value

        if (username.isBlank() || password.isBlank() || remotePath.isBlank() ||
            (localHost.isBlank() && tailscaleHost.isBlank())) {
            return@withContext Result.success()  // not configured yet
        }

        val sftp = SftpService(applicationContext)

        // Try local first, then Tailscale
        var connected = false
        for (host in listOf(localHost, tailscaleHost).filter { it.isNotBlank() }) {
            try {
                sftp.connect(host.trim(), port, username, password)
                connected = true
                break
            } catch (_: Exception) {}
        }
        if (!connected) return@withContext Result.retry()

        try {
            val uploadedIds = prefs.getStringSet("ids", emptySet())!!
                .mapNotNull { it.toLongOrNull() }.toMutableSet()

            val pending = MediaScanner.scanNewFiles(applicationContext, uploadedIds)
            if (pending.isEmpty()) return@withContext Result.success()

            var failed = 0
            for (file in pending) {
                val ok = sftp.uploadFile(file, remotePath)
                if (ok) {
                    uploadedIds.add(file.id)
                    prefs.edit().putStringSet("ids", uploadedIds.map { it.toString() }.toSet()).apply()
                } else {
                    failed++
                }
            }

            if (failed > 0 && failed == pending.size) Result.retry() else Result.success()
        } finally {
            sftp.disconnect()
        }
    }
}
