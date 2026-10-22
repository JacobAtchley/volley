package app.volley.android.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.resume

data class DiscoveredMac(val id: String, val name: String, val endpoint: Endpoint)

interface MacDiscovery {
    /** Cold flow: browsing runs while collected. */
    fun discover(): Flow<DiscoveredMac>
}

/** Bonjour/mDNS discovery of `_volley._tcp` via Android NSD. */
class NsdMacDiscovery(context: Context) : MacDiscovery {

    private val nsd = context.getSystemService(NsdManager::class.java)

    // Pre-API-34 NSD allows only one resolve at a time.
    private val resolveLock = Mutex()

    override fun discover(): Flow<DiscoveredMac> = callbackFlow {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                launch { resolve(info)?.let { send(it) } }
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                close(IllegalStateException("Discovery failed ($errorCode)"))
            }

            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }

        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        awaitClose { runCatching { nsd.stopServiceDiscovery(listener) } }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolve(info: NsdServiceInfo): DiscoveredMac? = resolveLock.withLock {
        suspendCancellableCoroutine { cont ->
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    if (cont.isActive) cont.resume(null)
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    if (cont.isActive) cont.resume(serviceInfo.toMac())
                }
            })
        }
    }

    @Suppress("DEPRECATION")
    private fun NsdServiceInfo.toMac(): DiscoveredMac? {
        val id = attributes["id"]?.toString(Charsets.UTF_8) ?: return null
        val host = host?.hostAddress ?: return null
        val name = attributes["name"]?.toString(Charsets.UTF_8) ?: serviceName
        return DiscoveredMac(id, name, Endpoint(host, port))
    }

    private companion object {
        const val SERVICE_TYPE = "_volley._tcp"
    }
}
