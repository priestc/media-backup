package com.example.mediabackup

import android.content.Context
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import java.text.SimpleDateFormat
import java.util.*

class SftpService(private val context: Context) {
    private var session: Session? = null
    private var sftp: ChannelSftp? = null

    fun connect(host: String, port: Int, username: String, privateKeyPath: String) {
        val jsch = JSch()
        jsch.addIdentity(privateKeyPath)
        val s = jsch.getSession(username, host, port)
        s.setConfig("StrictHostKeyChecking", "no")
        s.connect(30_000)
        val channel = s.openChannel("sftp") as ChannelSftp
        channel.connect()
        session = s
        sftp = channel
    }

    fun isConnected(): Boolean = session?.isConnected == true && sftp?.isConnected == true

    fun disconnect() {
        try { sftp?.disconnect() } catch (_: Exception) {}
        try { session?.disconnect() } catch (_: Exception) {}
        sftp = null
        session = null
    }

    fun uploadFile(file: MediaFile, remotePath: String): Boolean {
        val channel = sftp ?: return false
        return try {
            val date = if (file.dateTaken > 0) Date(file.dateTaken) else Date()
            val dateStr = SimpleDateFormat("yyyy/MM/dd", Locale.US).format(date)
            val deviceName = android.os.Build.MODEL.replace("/", "_")
            val remoteDir = "$remotePath/$deviceName/$dateStr"

            mkdirP(channel, remoteDir)

            val fullPath = "$remoteDir/${file.filename}"

            // Skip if already exists
            try {
                channel.lstat(fullPath)
                return true  // already uploaded
            } catch (_: Exception) {}

            context.contentResolver.openInputStream(file.uri)?.use { stream ->
                channel.put(stream, fullPath)
            }
            true
        } catch (_: Exception) { false }
    }

    private fun mkdirP(sftp: ChannelSftp, path: String) {
        var current = if (path.startsWith("/")) "/" else ""
        for (part in path.split("/").filter { it.isNotEmpty() }) {
            current += (if (current == "/") "" else "/") + part
            try { sftp.mkdir(current) } catch (_: Exception) {}
        }
    }
}
