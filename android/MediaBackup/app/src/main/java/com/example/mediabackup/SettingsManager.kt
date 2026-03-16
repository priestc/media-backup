package com.example.mediabackup

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class SettingsManager(context: Context) {
    private val prefs = context.getSharedPreferences("media_backup_prefs", Context.MODE_PRIVATE)

    private val _localURL     = MutableStateFlow(prefs.getString("localURL", "") ?: "")
    private val _tailscaleURL = MutableStateFlow(prefs.getString("tailscaleURL", "") ?: "")
    private val _apiKey       = MutableStateFlow(prefs.getString("apiKey", "") ?: "")

    val localURL:     StateFlow<String> = _localURL
    val tailscaleURL: StateFlow<String> = _tailscaleURL
    val apiKey:       StateFlow<String> = _apiKey

    fun setLocalURL(v: String)     { prefs.edit().putString("localURL", v).apply();     _localURL.value = v }
    fun setTailscaleURL(v: String) { prefs.edit().putString("tailscaleURL", v).apply(); _tailscaleURL.value = v }
    fun setApiKey(v: String)       { prefs.edit().putString("apiKey", v).apply();       _apiKey.value = v }
}
