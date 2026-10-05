package com.example.mediabackup

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class UploadWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    private val prefs: SharedPreferences =
        appContext.getSharedPreferences("uploaded_ids", Context.MODE_PRIVATE)

    override suspend fun getForegroundInfo(): ForegroundInfo {
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Backing up photos & videos")
            .setOngoing(true)
            .setSilent(true)
            .build()
        return if (Build.VERSION.SDK_INT >= 29) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    // Triggered, hourly and manual runs can overlap; serialize them so the same file
    // isn't uploaded twice concurrently.
    override suspend fun doWork(): Result = uploadLock.withLock { upload() }

    private suspend fun upload(): Result = withContext(Dispatchers.IO) {
        val app      = applicationContext as MediaBackupApp
        val settings = app.settingsManager

        val localHost     = settings.localHost.value
        val tailscaleHost = settings.tailscaleHost.value
        val port          = settings.port.value.toIntOrNull() ?: 22
        val username      = settings.username.value
        val remotePath    = settings.remotePath.value

        if (username.isBlank() || remotePath.isBlank() ||
            (localHost.isBlank() && tailscaleHost.isBlank())) {
            return@withContext Result.success()  // not configured yet
        }

        val keyManager = (applicationContext as MediaBackupApp).keyManager
        val sftp = SftpService(applicationContext)

        // Try local first, then Tailscale
        var connected = false
        for (host in listOf(localHost, tailscaleHost).filter { it.isNotBlank() }) {
            try {
                sftp.connect(host.trim(), port, username, keyManager.privateKeyPath)
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

            // Run as a foreground service so long video uploads aren't killed after 10 min.
            // Android 12+ may refuse this from the background; carry on regardless.
            try { setForeground(getForegroundInfo()) } catch (_: Exception) {}

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

    companion object {
        const val CHANNEL_ID = "uploads"
        private const val NOTIFICATION_ID = 1
        private const val WORK_NAME = "media_upload"
        private val uploadLock = Mutex()

        fun createNotificationChannel(context: Context) {
            val channel = NotificationChannel(CHANNEL_ID, "Uploads", NotificationManager.IMPORTANCE_LOW)
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<UploadWorker>()
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
                )
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
        }
    }
}
