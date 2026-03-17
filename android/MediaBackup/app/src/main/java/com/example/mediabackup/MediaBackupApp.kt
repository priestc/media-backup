package com.example.mediabackup

import android.app.Application
import androidx.work.*
import java.util.concurrent.TimeUnit

class MediaBackupApp : Application() {
    lateinit var settingsManager: SettingsManager
    lateinit var keyManager: KeyManager

    override fun onCreate() {
        super.onCreate()
        settingsManager = SettingsManager(this)
        keyManager = KeyManager(this)
        schedulePeriodicBackup()
    }

    private fun schedulePeriodicBackup() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val request = PeriodicWorkRequestBuilder<UploadWorker>(1, TimeUnit.HOURS)
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
            .build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "media_backup",
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }
}
