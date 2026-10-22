package app.volley.android

import android.app.Application
import android.content.Context
import android.os.Build
import app.volley.android.protocol.MsgType
import app.volley.android.session.PairingStore
import app.volley.android.session.SessionManager
import app.volley.android.sms.SmsSendHandler
import app.volley.android.sms.SystemSmsSender
import app.volley.android.transport.LanTransportFactory
import app.volley.android.transport.MacDiscovery
import app.volley.android.transport.NsdMacDiscovery
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

class VolleyApp : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this)
    }
}

val Context.graph: AppGraph get() = (applicationContext as VolleyApp).graph

/** Manual composition root. Swap implementations here (e.g. a relay TransportFactory). */
class AppGraph(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val http = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    val pairing = PairingStore(context)
    val discovery: MacDiscovery = NsdMacDiscovery(context)

    val session = SessionManager(
        discovery = discovery,
        transports = LanTransportFactory(http),
        store = pairing,
        scope = scope,
        deviceName = Build.MODEL,
    ).also {
        it.on(MsgType.SMS_SEND, SmsSendHandler(SystemSmsSender(context), it))
    }
}
