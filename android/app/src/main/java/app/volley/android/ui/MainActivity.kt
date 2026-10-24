package app.volley.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.volley.android.graph
import app.volley.android.notifications.TestNotifications
import app.volley.android.session.SessionState
import app.volley.android.transport.DiscoveredMac

private val Coral = Color(0xFFFF9E8F)
private val Blush = Color(0xFFFFE3DB)
private val Cocoa = Color(0xFF2A1F1D)
private val Shell = Color(0xFFFFF6F2)
private val Muted = Color(0xFF6B5753)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(
                colorScheme = lightColorScheme(
                    primary = Coral,
                    onPrimary = Cocoa,
                    background = Shell,
                    onBackground = Cocoa,
                    surface = Color.White,
                    onSurface = Cocoa,
                ),
            ) {
                Surface(Modifier.fillMaxSize(), color = Shell) { VolleyScreen() }
            }
        }
    }
}

@Composable
private fun VolleyScreen() {
    val context = LocalContext.current
    val graph = context.graph
    val state by graph.session.state.collectAsStateWithLifecycle()
    val pairing by graph.pairing.pairing.collectAsStateWithLifecycle()

    var smsGranted by remember { mutableStateOf(false) }
    var contactsGranted by remember { mutableStateOf(false) }
    var phoneNumberGranted by remember { mutableStateOf(false) }
    var filesGranted by remember { mutableStateOf(false) }
    var listenerEnabled by remember { mutableStateOf(false) }
    LifecycleResumeEffect(Unit) {
        smsGranted = SMS_PERMISSIONS.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        filesGranted = hasAllFilesAccess(context)
        graph.refreshFileAccess()
        contactsGranted = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED
        phoneNumberGranted = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_NUMBERS) ==
            PackageManager.PERMISSION_GRANTED
        listenerEnabled = context.packageName in NotificationManagerCompat.getEnabledListenerPackages(context)
        onPauseOrDispose { }
    }
    val smsLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
        smsGranted = r.values.all { it }
    }
    val contactsLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        contactsGranted = it
    }
    val phoneNumberLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        phoneNumberGranted = it
    }
    val legacyFilesLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            filesGranted = hasAllFilesAccess(context)
            graph.refreshFileAccess()
        }
    val postLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) TestNotifications.post(context)
    }

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            VolleyMark(Modifier.size(44.dp))
            Spacer(Modifier.width(12.dp))
            Text("volley", fontSize = 34.sp, fontWeight = FontWeight.Bold, color = Cocoa)
        }

        Section("Status") { Text(state.label(), fontSize = 16.sp) }

        Section("Permissions") {
            PermissionRow("Text messages", smsGranted) { smsLauncher.launch(SMS_PERMISSIONS) }
            PermissionRow("Contacts", contactsGranted) { contactsLauncher.launch(Manifest.permission.READ_CONTACTS) }
            // Keeps this phone out of group replies.
            PermissionRow("Phone number", phoneNumberGranted) {
                phoneNumberLauncher.launch(Manifest.permission.READ_PHONE_NUMBERS)
            }
            PermissionRow("All files access", filesGranted) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    context.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:${context.packageName}"),
                        ),
                    )
                } else {
                    legacyFilesLauncher.launch(
                        arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    )
                }
            }
            PermissionRow("Notification access", listenerEnabled) {
                context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            }
        }

        Section("Testing") {
            OutlinedButton(onClick = {
                val needsPermission = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED
                if (needsPermission) {
                    postLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    TestNotifications.post(context)
                }
            }) { Text("Send test notification", color = Cocoa) }
        }

        val paired = pairing
        if (paired != null) {
            Section("Paired Mac") {
                Text(paired.macName, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                TextButton(onClick = { graph.session.unpair() }) { Text("Unpair", color = Cocoa) }
            }
        } else {
            PairSection(onPair = { mac, code -> graph.session.pair(mac, code) })
        }
    }
}

@Composable
private fun PairSection(onPair: (DiscoveredMac, String) -> Unit) {
    val discovery = LocalContext.current.graph.discovery
    val macs = remember { mutableStateListOf<DiscoveredMac>() }
    var selected by remember { mutableStateOf<DiscoveredMac?>(null) }
    var code by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        runCatching {
            discovery.discover().collect { mac ->
                val i = macs.indexOfFirst { it.id == mac.id }
                if (i >= 0) macs[i] = mac else macs.add(mac)
            }
        }
    }

    Section("Pair with your Mac") {
        if (macs.isEmpty()) {
            Text("Open Volley on your Mac. It will appear here when it's on the same Wi-Fi.", color = Muted)
        }
        macs.forEach { mac ->
            OutlinedButton(onClick = { selected = mac }, modifier = Modifier.fillMaxWidth()) {
                Text(if (selected?.id == mac.id) "${mac.name} (selected)" else mac.name, color = Cocoa)
            }
        }
        selected?.let { mac ->
            OutlinedTextField(
                value = code,
                onValueChange = { v -> code = v.filter(Char::isDigit).take(6) },
                label = { Text("6-digit code shown on the Mac") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Button(onClick = { onPair(mac, code) }, enabled = code.length == 6, modifier = Modifier.fillMaxWidth()) {
                Text("Pair", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                title.uppercase(),
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = Muted,
                letterSpacing = 1.sp,
            )
            content()
        }
    }
}

@Composable
private fun PermissionRow(label: String, granted: Boolean, onGrant: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), fontSize = 16.sp)
        if (granted) {
            Surface(shape = RoundedCornerShape(10.dp), color = Blush) {
                Text("Granted", Modifier.padding(horizontal = 12.dp, vertical = 6.dp), fontSize = 14.sp)
            }
        } else {
            Button(onClick = onGrant) { Text("Grant") }
        }
    }
}

/** The Volley mark: an arc served from one dot to another. */
@Composable
private fun VolleyMark(modifier: Modifier = Modifier) {
    Surface(modifier, shape = RoundedCornerShape(12.dp), color = Coral) {
        Canvas(Modifier.fillMaxSize()) {
            val s = size.width / 64f
            val stroke = 5f * s
            val path = Path().apply {
                moveTo(13 * s, 45 * s)
                quadraticTo(32 * s, 4 * s, 51 * s, 45 * s)
            }
            drawPath(path, Cocoa, style = Stroke(width = stroke, cap = StrokeCap.Round))
            drawCircle(Cocoa, 5 * s, Offset(13 * s, 45 * s))
            drawCircle(Cocoa, 5 * s, Offset(51 * s, 45 * s))
        }
    }
}

private fun SessionState.label(): String = when (this) {
    SessionState.Unpaired -> "Not paired"
    SessionState.Idle -> "Waiting to reconnect"
    SessionState.Searching -> "Looking for your Mac"
    is SessionState.Connecting -> "Connecting to $macName"
    is SessionState.Connected -> "Connected to $macName"
    is SessionState.Failed -> message
}

private fun hasAllFilesAccess(context: android.content.Context): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
    }

private val SMS_PERMISSIONS = arrayOf(
    Manifest.permission.RECEIVE_SMS,
    Manifest.permission.SEND_SMS,
    Manifest.permission.READ_SMS,
)
