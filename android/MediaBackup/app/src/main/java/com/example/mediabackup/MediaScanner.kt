package com.example.mediabackup

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import java.io.File

data class MediaFile(
    val id: Long,
    val uri: Uri,
    val filename: String,
    val mimeType: String,
    val dateTaken: Long,   // epoch millis
    val size: Long,
)

object MediaScanner {
    fun scanNewFiles(context: Context, uploadedIds: Set<Long>): List<MediaFile> {
        val results = mutableListOf<MediaFile>()
        for ((collection, mime) in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI to "image/*",
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI  to "video/*",
        )) {
            results += query(context, collection, mime, uploadedIds)
        }
        return results.sortedBy { it.dateTaken }
    }

    private fun query(context: Context, collection: Uri, mimePrefix: String, uploadedIds: Set<Long>): List<MediaFile> {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.SIZE,
        )
        val results = mutableListOf<MediaFile>()
        context.contentResolver.query(collection, projection, null, null, "${MediaStore.MediaColumns.DATE_TAKEN} ASC")
            ?.use { cursor ->
                val idCol       = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameCol     = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val mimeCol     = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val dateCol     = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
                val sizeCol     = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)

                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    if (id in uploadedIds) continue
                    val uri = Uri.withAppendedPath(collection, id.toString())
                    results += MediaFile(
                        id        = id,
                        uri       = uri,
                        filename  = cursor.getString(nameCol) ?: "file_$id",
                        mimeType  = cursor.getString(mimeCol) ?: "application/octet-stream",
                        dateTaken = cursor.getLong(dateCol),
                        size      = cursor.getLong(sizeCol),
                    )
                }
            }
        return results
    }
}
