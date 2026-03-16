package com.example.mediabackup

import android.app.Service
import android.content.Intent
import android.os.IBinder

// Declared in manifest for foregroundServiceType=dataSync.
// WorkManager uses this automatically when running expedited work on Android 12+.
class UploadForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
}
