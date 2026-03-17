package com.example.mediabackup

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class SettingsManager(context: Context) {
    private val prefs = context.getSharedPreferences("media_backup_prefs", Context.MODE_PRIVATE)

    private fun flow(key: String, default: String = "") =
        MutableStateFlow(prefs.getString(key, default) ?: default)

    private fun set(key: String, flow: MutableStateFlow<String>, value: String) {
        prefs.edit().putString(key, value).apply()
        flow.value = value
    }

    private val _localHost     = flow("sshLocalHost")
    private val _tailscaleHost = flow("sshTailscaleHost")
    private val _port          = flow("sshPort", "22")
    private val _username      = flow("sshUsername")
    private val _password      = flow("sshPassword")
    private val _remotePath    = flow("sshRemotePath")

    val localHost:     StateFlow<String> = _localHost
    val tailscaleHost: StateFlow<String> = _tailscaleHost
    val port:          StateFlow<String> = _port
    val username:      StateFlow<String> = _username
    val password:      StateFlow<String> = _password
    val remotePath:    StateFlow<String> = _remotePath

    fun setLocalHost(v: String)     = set("sshLocalHost",     _localHost,     v)
    fun setTailscaleHost(v: String) = set("sshTailscaleHost", _tailscaleHost, v)
    fun setPort(v: String)          = set("sshPort",          _port,          v)
    fun setUsername(v: String)      = set("sshUsername",      _username,      v)
    fun setPassword(v: String)      = set("sshPassword",      _password,      v)
    fun setRemotePath(v: String)    = set("sshRemotePath",    _remotePath,    v)
}
