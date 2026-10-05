package com.example.mediabackup

import android.content.Context
import android.provider.MediaStore
import androidx.work.*
import java.util.concurrent.TimeUnit

// Woken by the OS whenever MediaStore changes (new photo or video), even when the
// app isn't running. Kicks off an upload, then re-arms itself for the next change —
// content-URI triggers are one-shot.
class MediaTriggerWorker(appContext: Context, params: WorkerParameters) :
    Worker(appContext, params) {

    override fun doWork(): Result {
        UploadWorker.enqueue(applicationContext)
        schedule(applicationContext, ExistingWorkPolicy.APPEND_OR_REPLACE)
        return Result.success()
    }

    companion object {
        private const val WORK_NAME = "media_trigger"

        fun schedule(context: Context, policy: ExistingWorkPolicy = ExistingWorkPolicy.KEEP) {
            val constraints = Constraints.Builder()
                .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
                .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
                // Coalesce bursts (e.g. burst shots) and let video files finish writing
                .setTriggerContentUpdateDelay(5, TimeUnit.SECONDS)
                .setTriggerContentMaxDelay(30, TimeUnit.SECONDS)
                .build()

            val request = OneTimeWorkRequestBuilder<MediaTriggerWorker>()
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, policy, request)
        }
    }
}
