package app.volley.android

import android.app.Application
import android.content.Context
import android.os.Build
import app.volley.android.files.AndroidFiles
import app.volley.android.files.DiskFileService
import app.volley.android.files.FileHandlers
import app.volley.android.files.StoragePaths
import app.volley.android.notifications.ExcludedPackages
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.NotificationFilter
import app.volley.android.protocol.bodyAs
import app.volley.android.session.PairingStore
import app.volley.android.session.SessionManager
import app.volley.android.session.SessionState
import app.volley.android.sms.ContentResolverSmsSource
import app.volley.android.sms.PhoneLookupContactNames
import app.volley.android.sms.SmsObserver
import app.volley.android.sms.SmsSendHandler
import app.volley.android.sms.SmsSyncHandler
import app.volley.android.sms.SmsSyncer
import app.volley.android.sms.SystemSmsSender
import app.volley.android.status.DeviceStatusReporter
import app.volley.android.transport.LanTransportFactory
import app.volley.android.transport.MacDiscovery
import app.volley.android.transport.NsdMacDiscovery
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
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
    val excludedPackages = ExcludedPackages(context)
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

    private val syncer = SmsSyncer(
        source = ContentResolverSmsSource(context.contentResolver),
        names = PhoneLookupContactNames(context.contentResolver),
        send = { session.send(it) },
    )
    private val smsObserver = SmsObserver(context.contentResolver, scope) { syncer.onChanged() }
    private val statusReporter = DeviceStatusReporter(context, scope) { session.send(it) }

    private val androidFiles = AndroidFiles(context)
    private val fileHandlers = FileHandlers(
        files = DiskFileService(StoragePaths(androidFiles.root), androidFiles::thumbnail),
        send = { session.send(it) },
        sendBinary = { session.sendBinary(it) },
        hasAccess = androidFiles::hasAccess,
        onTransferActive = androidFiles::setTransferActive,
        scan = androidFiles::scan,
    )
    private var lastFileAccess: Boolean? = null

    /** Tells the Mac if All files access changed (call when returning from the permission screen). */
    fun refreshFileAccess() {
        val access = androidFiles.hasAccess()
        if (access != lastFileAccess && session.send(fileHandlers.statusFrame())) lastFileAccess = access
    }

    init {
        fileHandlers.types.forEach { type -> session.on(type) { fileHandlers.handle(it) } }
        session.onBinary = fileHandlers::onBinary
        session.on(MsgType.SMS_SYNC, SmsSyncHandler(syncer))
        session.on(MsgType.NOTIFICATION_FILTER) { env ->
            env.bodyAs<NotificationFilter>()?.let { excludedPackages.set(it.excludedPackages.toSet()) }
        }
        // Stream SMS changes and phone status only while a Mac is connected; it asks for a fresh sync each time.
        scope.launch {
            session.state.collect { state ->
                if (state is SessionState.Connected) {
                    smsObserver.start()
                    statusReporter.start()
                    lastFileAccess = null
                    refreshFileAccess()
                } else {
                    smsObserver.stop()
                    statusReporter.stop()
                    syncer.reset()
                    fileHandlers.onDisconnect()
                }
            }
        }
    }
}
