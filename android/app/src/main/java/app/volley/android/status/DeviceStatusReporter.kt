package app.volley.android.status

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.SystemClock
import android.telephony.SignalStrength
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.annotation.RequiresApi
import app.volley.android.protocol.Codec
import app.volley.android.protocol.DeviceStatus
import app.volley.android.protocol.MsgType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.Executors

sealed interface Decision {
    data object Send : Decision
    data object Skip : Decision
    data class Defer(val atMs: Long) : Decision
}

/** Decides when a status change is worth sending: changes only, at most once per [minIntervalMs]. */
class StatusThrottle(private val minIntervalMs: Long = 30_000) {
    private var last: DeviceStatus? = null
    private var lastSentMs = 0L

    fun offer(status: DeviceStatus, nowMs: Long): Decision {
        val prev = last
        val decision = when {
            prev == null -> Decision.Send
            prev == status -> Decision.Skip
            prev.charging != status.charging -> Decision.Send
            nowMs - lastSentMs >= minIntervalMs -> Decision.Send
            else -> Decision.Defer(lastSentMs + minIntervalMs)
        }
        if (decision == Decision.Send) {
            last = status
            lastSentMs = nowMs
        }
        return decision
    }

    fun reset() {
        last = null
        lastSentMs = 0
    }
}

/**
 * Sends `device.status` (battery, charging, cell and Wi-Fi bars) while started. No polling.
 * Live cell updates need API 29+; below that cell bars are reported as unknown.
 */
class DeviceStatusReporter(
    private val context: Context,
    private val scope: CoroutineScope,
    private val send: (String) -> Unit,
) {
    private val telephony = context.getSystemService(TelephonyManager::class.java)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val throttle = StatusThrottle()
    private val callbackExecutor = Executors.newSingleThreadExecutor()

    private var started = false
    private var deferred: Job? = null
    private var battery = 0
    private var charging = false
    private var cellLevel: Int? = null
    private var wifiLevel: Int? = null
    private var wifiConnected = false
    private var cellListener: Any? = null

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = onBattery(intent)
    }

    private val wifiCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = update {
            wifiConnected = true
            wifiLevel = wifiLevelOf(caps)
        }

        override fun onLost(network: Network) = update {
            wifiConnected = false
            wifiLevel = null
        }
    }

    @Synchronized
    fun start() {
        if (started) return
        started = true
        context.registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.let(::readBattery)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) cellLevel = telephony?.signalStrength?.level
        registerCell()
        connectivity?.registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
            wifiCallback,
        )
        offer()
    }

    @Synchronized
    fun stop() {
        if (!started) return
        started = false
        context.unregisterReceiver(batteryReceiver)
        unregisterCell()
        runCatching { connectivity?.unregisterNetworkCallback(wifiCallback) }
        deferred?.cancel()
        deferred = null
        throttle.reset()
    }

    private fun onBattery(intent: Intent) = update { readBattery(intent) }

    private fun readBattery(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        if (level >= 0 && scale > 0) battery = level * 100 / scale
        charging = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
    }

    @Synchronized
    private fun update(change: () -> Unit) {
        if (!started) return
        change()
        offer()
    }

    @Synchronized
    private fun offer() {
        val status = DeviceStatus(battery, charging, cellLevel, wifiLevel, wifiConnected)
        when (val d = throttle.offer(status, SystemClock.elapsedRealtime())) {
            Decision.Send -> send(Codec.encode(MsgType.DEVICE_STATUS, status))
            Decision.Skip -> Unit
            is Decision.Defer -> if (deferred?.isActive != true) {
                deferred = scope.launch {
                    delay(d.atMs - SystemClock.elapsedRealtime())
                    synchronized(this@DeviceStatusReporter) { if (started) offer() }
                }
            }
        }
    }

    private fun onSignal(strength: SignalStrength) = update { cellLevel = strength.level }

    // PhoneStateListener is the only option on API 29–30; TelephonyCallback replaces it from 31.
    @Suppress("DEPRECATION")
    private fun registerCell() {
        val tm = telephony ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val cb = SignalCallback()
            tm.registerTelephonyCallback(callbackExecutor, cb)
            cellListener = cb
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val listener = object : android.telephony.PhoneStateListener(callbackExecutor) {
                @Deprecated("Deprecated in Java")
                override fun onSignalStrengthsChanged(strength: SignalStrength) = onSignal(strength)
            }
            tm.listen(listener, android.telephony.PhoneStateListener.LISTEN_SIGNAL_STRENGTHS)
            cellListener = listener
        }
    }

    @Suppress("DEPRECATION")
    private fun unregisterCell() {
        val tm = telephony ?: return
        when (val l = cellListener) {
            is android.telephony.PhoneStateListener ->
                tm.listen(l, android.telephony.PhoneStateListener.LISTEN_NONE)
            null -> Unit
            else -> if (Build.VERSION.SDK_INT >=
                Build.VERSION_CODES.S
            ) {
                tm.unregisterTelephonyCallback(l as TelephonyCallback)
            }
        }
        cellListener = null
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private inner class SignalCallback :
        TelephonyCallback(),
        TelephonyCallback.SignalStrengthsListener {
        override fun onSignalStrengthsChanged(strength: SignalStrength) = onSignal(strength)
    }

    /** RSSI → 0–4 bars, or null when unknown. */
    private fun wifiLevelOf(caps: NetworkCapabilities): Int? {
        val rssi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            caps.signalStrength
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(WifiManager::class.java)?.connectionInfo?.rssi
                ?: UNKNOWN_RSSI
        }
        if (rssi == UNKNOWN_RSSI) return null
        @Suppress("DEPRECATION")
        return WifiManager.calculateSignalLevel(rssi, 5)
    }
}

/** Same value as `NetworkCapabilities.SIGNAL_STRENGTH_UNSPECIFIED`, which only exists from API 29. */
private const val UNKNOWN_RSSI = Int.MIN_VALUE
