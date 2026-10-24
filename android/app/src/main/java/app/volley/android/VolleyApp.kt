package app.volley.android

import android.app.Application
import android.content.Context
import android.os.Build
import app.volley.android.files.AndroidFiles
import app.volley.android.files.DiskFileService
import app.volley.android.files.FileHandlers
import app.volley.android.files.StoragePaths
import app.volley.android.mms.AndroidMmsParts
import app.volley.android.mms.MmsHandlers
import app.volley.android.mms.MmsSender
import app.volley.android.notifications.ExcludedPackages
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.NotificationFilter
import app.volley.android.protocol.bodyAs
import app.volley.android.session.PairingStore
import app.volley.android.session.SessionManager
import app.volley.android.session.SessionState
import app.volley.android.sms.AndroidOwnNumber
import app.volley.android.sms.ContentResolverMmsSource
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
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.ThreadPoolExecutor.DiscardOldestPolicy
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

    private val mmsSource = ContentResolverMmsSource(context.contentResolver)
    private val ownNumber = AndroidOwnNumber(context, mmsSource)
    private val syncer = SmsSyncer(
        source = ContentResolverSmsSource(context.contentResolver),
        names = PhoneLookupContactNames(context.contentResolver),
        mms = mmsSource,
        ownNumber = ownNumber::get,
        send = { session.send(it) },
    )
    private val smsObserver = SmsObserver(context.contentResolver, scope) { syncer.onChanged() }
    private val statusReporter = DeviceStatusReporter(context, scope) { session.send(it) }

    private val androidFiles = AndroidFiles(context)
    private val fileHandlers = FileHandlers(
        files = DiskFileService(
            StoragePaths(androidFiles.root),
            mediaThumbnail = androidFiles::mediaThumbnail,
            thumbnails = androidFiles::thumbnail,
        ),
        send = { session.send(it) },
        sendBinary = { session.sendBinary(it) },
        hasAccess = androidFiles::hasAccess,
        onTransferActive = androidFiles::setTransferActive,
        scan = androidFiles::scan,
        // One worker, newest 64 requests: scrolling a huge photo folder can't pile up stale thumbnails.
        background = ThreadPoolExecutor(
            1,
            1,
            0,
            TimeUnit.SECONDS,
            LinkedBlockingQueue(64),
            DiscardOldestPolicy(),
        )::execute,
    )
    private val mmsHandlers = MmsHandlers(
        parts = AndroidMmsParts(context.contentResolver),
        transfers = fileHandlers,
        sender = MmsSender(context),
        attachDir = File(context.cacheDir, "mms-out"),
        send = { session.send(it) },
        // Like file thumbnails: one worker, newest requests win while scrolling.
        thumbs = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, LinkedBlockingQueue(64), DiscardOldestPolicy())::execute,
        sends = Executors.newSingleThreadExecutor()::execute,
        ownNumber = ownNumber::get,
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
        mmsHandlers.types.forEach { type -> session.on(type) { mmsHandlers.handle(it) } }
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
                    mmsHandlers.onDisconnect()
                }
            }
        }
    }
}
