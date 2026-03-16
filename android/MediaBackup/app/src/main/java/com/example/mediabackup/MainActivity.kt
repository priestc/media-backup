package com.example.mediabackup

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.work.*
import kotlinx.coroutines.*

class MainActivity : ComponentActivity() {
    private lateinit var app: MediaBackupApp

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { /* handled via recompose */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as MediaBackupApp
        setContent { MediaBackupUI(app, ::requestPermissions, ::runBackupNow) }
    }

    private fun requestPermissions() {
        val needed = buildList {
            if (Build.VERSION.SDK_INT >= 33) {
                add(Manifest.permission.READ_MEDIA_IMAGES)
                add(Manifest.permission.READ_MEDIA_VIDEO)
                add(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                add(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
        }.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isNotEmpty()) permissionLauncher.launch(needed.toTypedArray())
    }

    private fun runBackupNow() {
        val request = OneTimeWorkRequestBuilder<UploadWorker>()
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        WorkManager.getInstance(this).enqueue(request)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaBackupUI(app: MediaBackupApp, requestPermissions: () -> Unit, runNow: () -> Unit) {
    val settings = app.settingsManager
    var showSettings by remember { mutableStateOf(false) }
    var backupStatus by remember { mutableStateOf("Tap 'Backup Now' to start") }
    var isRunning by remember { mutableStateOf(false) }

    val scope = rememberCoroutineScope()

    MaterialTheme {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("Media Backup") },
                    actions = {
                        IconButton(onClick = { showSettings = !showSettings }) {
                            Icon(Icons.Default.Settings, "Settings")
                        }
                    }
                )
            }
        ) { padding ->
            if (showSettings) {
                SettingsPanel(settings, modifier = Modifier.padding(padding)) {
                    showSettings = false
                }
            } else {
                MainPanel(
                    status = backupStatus,
                    isRunning = isRunning,
                    modifier = Modifier.padding(padding),
                    onBackupNow = {
                        requestPermissions()
                        runNow()
                        backupStatus = "Backup queued — running in background…"
                    }
                )
            }
        }
    }
}

@Composable
fun MainPanel(status: String, isRunning: Boolean, modifier: Modifier, onBackupNow: () -> Unit) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Default.CloudUpload,
            contentDescription = null,
            modifier = Modifier.size(72.dp),
            tint = MaterialTheme.colorScheme.primary,
        )
        Spacer(Modifier.height(16.dp))
        Text(status, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(32.dp))
        Button(onClick = onBackupNow, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Default.Backup, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("Backup Now")
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "Automatic backup also runs hourly when connected to a network.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
fun SettingsPanel(settings: SettingsManager, modifier: Modifier, onClose: () -> Unit) {
    val localURL     by settings.localURL.collectAsStateWithLifecycle()
    val tailscaleURL by settings.tailscaleURL.collectAsStateWithLifecycle()
    val apiKey       by settings.apiKey.collectAsStateWithLifecycle()

    Column(modifier = modifier.fillMaxSize().padding(16.dp)) {
        Text("Settings", style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(16.dp))

        OutlinedTextField(
            value = localURL,
            onValueChange = { settings.setLocalURL(it) },
            label = { Text("Local IP") },
            placeholder = { Text("192.168.1.x:8765") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = tailscaleURL,
            onValueChange = { settings.setTailscaleURL(it) },
            label = { Text("Tailscale IP") },
            placeholder = { Text("100.x.x.x:8765") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = apiKey,
            onValueChange = { settings.setApiKey(it) },
            label = { Text("API Key") },
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(16.dp))
        Button(onClick = onClose, modifier = Modifier.fillMaxWidth()) {
            Text("Save & Close")
        }
    }
}
