package app.volley.android.transport

import kotlinx.coroutines.flow.Flow

/** Where a Mac can be reached. Relay endpoints can be added later as another subtype. */
data class Endpoint(val host: String, val port: Int) {
    val url: String get() = "ws://${if (':' in host) "[$host]" else host}:$port/"
}

sealed interface TransportEvent {
    data object Open : TransportEvent
    data class Text(val text: String) : TransportEvent

    class Binary(val bytes: ByteArray) : TransportEvent
    data class Closed(val reason: String?) : TransportEvent
}

/** A single bidirectional connection to a Mac. Implementations: [LanTransport]; a relay later. */
interface Transport {
    /** Hot stream of events; completes after [TransportEvent.Closed]. */
    val events: Flow<TransportEvent>
    fun send(text: String): Boolean

    fun sendBinary(bytes: ByteArray): Boolean
    fun close()
}

fun interface TransportFactory {
    fun open(endpoint: Endpoint): Transport
}
