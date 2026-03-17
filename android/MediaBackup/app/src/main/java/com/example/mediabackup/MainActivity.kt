package com.example.mediabackup

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
    val localHost     by settings.localHost.collectAsStateWithLifecycle()
    val tailscaleHost by settings.tailscaleHost.collectAsStateWithLifecycle()
    val port          by settings.port.collectAsStateWithLifecycle()
    val username      by settings.username.collectAsStateWithLifecycle()
    val password      by settings.password.collectAsStateWithLifecycle()
    val remotePath    by settings.remotePath.collectAsStateWithLifecycle()

    Column(modifier = modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState())) {
        Text("Settings", style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(16.dp))

        OutlinedTextField(
            value = localHost,
            onValueChange = { settings.setLocalHost(it) },
            label = { Text("Local IP") },
            placeholder = { Text("192.168.1.x") },
            singleLine = true, modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = tailscaleHost,
            onValueChange = { settings.setTailscaleHost(it) },
            label = { Text("Tailscale IP") },
            placeholder = { Text("100.x.x.x") },
            singleLine = true, modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = port,
            onValueChange = { settings.setPort(it) },
            label = { Text("SSH Port") },
            placeholder = { Text("22") },
            singleLine = true, modifier = Modifier.fillMaxWidth(),
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                keyboardType = androidx.compose.ui.text.input.KeyboardType.Number
            ),
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = username,
            onValueChange = { settings.setUsername(it) },
            label = { Text("SSH Username") },
            singleLine = true, modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = password,
            onValueChange = { settings.setPassword(it) },
            label = { Text("SSH Password") },
            singleLine = true,
            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = remotePath,
            onValueChange = { settings.setRemotePath(it) },
            label = { Text("Remote Path") },
            placeholder = { Text("/home/chris/photos") },
            singleLine = true, modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(16.dp))
        Button(onClick = onClose, modifier = Modifier.fillMaxWidth()) {
            Text("Save & Close")
        }
    }
}
