package com.example.mediabackup

import android.content.Context
import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
import java.io.File

class KeyManager(private val context: Context) {
    private val privateKeyFile = File(context.filesDir, "id_ed25519")
    private val publicKeyFile  = File(context.filesDir, "id_ed25519.pub")

    init { ensureKeyExists() }

    private fun ensureKeyExists() {
        if (!privateKeyFile.exists()) {
            val jsch = JSch()
            val kp = KeyPair.genKeyPair(jsch, KeyPair.ED25519)
            kp.writePrivateKey(privateKeyFile.absolutePath)
            kp.writePublicKey(publicKeyFile.absolutePath, "media-backup-android")
            kp.dispose()
        }
    }

    val privateKeyPath: String get() = privateKeyFile.absolutePath

    val publicKeyString: String get() = publicKeyFile.readText().trim()
}
