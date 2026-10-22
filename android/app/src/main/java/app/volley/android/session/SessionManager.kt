package app.volley.android.session

import app.volley.android.protocol.Codec
import app.volley.android.protocol.Envelope
import app.volley.android.protocol.Hello
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.PairRequest
import app.volley.android.protocol.PairResult
import app.volley.android.protocol.bodyAs
import app.volley.android.transport.DiscoveredMac
import app.volley.android.transport.MacDiscovery
import app.volley.android.transport.Transport
import app.volley.android.transport.TransportEvent
import app.volley.android.transport.TransportFactory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

sealed interface SessionState {
    data object Unpaired : SessionState
    data object Idle : SessionState
    data object Searching : SessionState
    data class Connecting(val macName: String) : SessionState
    data class Connected(val macName: String) : SessionState
    data class Failed(val message: String) : SessionState
}

/** Inbound message handler, keyed by [Envelope.type]. */
fun interface MessageHandler {
    fun handle(envelope: Envelope)
}

/**
 * Owns the connection lifecycle: discover the paired Mac, connect, authenticate,
 * route inbound messages to handlers, and reconnect with backoff.
 */
class SessionManager(
    private val discovery: MacDiscovery,
    private val transports: TransportFactory,
    private val store: PairingStore,
    private val scope: CoroutineScope,
    private val deviceName: String,
) {
    private val _state = MutableStateFlow<SessionState>(
        if (store.pairing.value == null) SessionState.Unpaired else SessionState.Idle,
    )
    val state: StateFlow<SessionState> = _state.asStateFlow()

    private val handlers = ConcurrentHashMap<String, MessageHandler>()
    private val pending = ArrayDeque<String>()

    @Volatile private var active: Transport? = null
    @Volatile private var authed = false
    private var loop: Job? = null

    fun on(type: String, handler: MessageHandler) { handlers[type] = handler }
    fun off(type: String) { handlers.remove(type) }

    @Synchronized
    fun start() {
        if (loop?.isActive == true) return
        loop = scope.launch { runLoop() }
    }

    @Synchronized
    fun stop() {
        loop?.cancel()
        loop = null
        active?.close()
    }

    /** Pair with [mac] using the code shown on it, then keep the session running. */
    @Synchronized
    fun pair(mac: DiscoveredMac, code: String) {
        stop()
        _state.value = SessionState.Connecting(mac.name)
        val frame = Codec.encode(MsgType.PAIR_REQUEST, PairRequest(store.deviceId, deviceName, code))
        loop = scope.launch {
            val paired = try {
                connect(mac, frame)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                false
            }
            when {
                paired -> runLoop()
                _state.value !is SessionState.Failed -> _state.value = SessionState.Failed("Couldn't reach ${mac.name}")
            }
        }
    }

    @Synchronized
    fun unpair() {
        stop()
        store.clear()
        synchronized(pending) { pending.clear() }
        _state.value = SessionState.Unpaired
    }

    /** Sends a pre-encoded frame. When offline, optionally buffers it (bounded) for the next connection. */
    fun send(frame: String, bufferIfOffline: Boolean = false): Boolean {
        val t = active
        if (t != null && authed && t.send(frame)) return true
        if (bufferIfOffline) synchronized(pending) {
            if (pending.size >= MAX_PENDING) pending.removeFirst()
            pending.addLast(frame)
        }
        return false
    }

    private suspend fun runLoop() {
        var backoff = MIN_BACKOFF_MS
        while (currentCoroutineContext().isActive) {
            val pairing = store.pairing.value
            if (pairing == null) {
                _state.value = SessionState.Unpaired
                return
            }
            try {
                _state.value = SessionState.Searching
                val mac = discovery.discover().first { it.id == pairing.macId }
                val hello = Codec.encode(MsgType.HELLO, Hello(store.deviceId, deviceName, pairing.token))
                if (connect(mac, hello)) backoff = MIN_BACKOFF_MS
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.value = SessionState.Failed(e.message ?: "Connection error")
            }
            if (store.pairing.value == null) continue
            if (_state.value !is SessionState.Failed) _state.value = SessionState.Idle
            delay(backoff)
            backoff = (backoff * 2).coerceAtMost(MAX_BACKOFF_MS)
        }
    }

    /** Runs one connection until it closes. Returns true if it authenticated. */
    private suspend fun connect(mac: DiscoveredMac, firstFrame: String): Boolean {
        _state.value = SessionState.Connecting(mac.name)
        val transport = transports.open(mac.endpoint)
        active = transport
        var ok = false
        try {
            transport.events.takeWhile { it !is TransportEvent.Closed }.collect { event ->
                when (event) {
                    TransportEvent.Open -> transport.send(firstFrame)
                    is TransportEvent.Text -> {
                        val env = Codec.decode(event.text) ?: return@collect
                        when (env.type) {
                            MsgType.HELLO_OK -> { ok = true; onAuthed(transport, mac.name) }
                            MsgType.PAIR_RESULT -> {
                                val r = env.bodyAs<PairResult>()
                                if (r?.ok == true && r.token != null) {
                                    store.save(Pairing(r.macId, r.macName, r.token))
                                    ok = true
                                    onAuthed(transport, r.macName)
                                } else {
                                    _state.value = SessionState.Failed("Pairing code rejected")
                                    transport.close()
                                }
                            }
                            else -> if (authed) handlers[env.type]?.handle(env)
                        }
                    }
                    is TransportEvent.Closed -> Unit
                }
            }
        } finally {
            authed = false
            active = null
            transport.close()
        }
        return ok
    }

    private fun onAuthed(transport: Transport, macName: String) {
        authed = true
        _state.value = SessionState.Connected(macName)
        synchronized(pending) {
            while (pending.isNotEmpty() && transport.send(pending.first())) pending.removeFirst()
        }
    }

    private companion object {
        const val MAX_PENDING = 50
        const val MIN_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 30_000L
    }
}
