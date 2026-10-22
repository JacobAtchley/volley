package app.volley.android.transport

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** WebSocket over the local network. One instance per connection attempt. */
class LanTransport(client: OkHttpClient, endpoint: Endpoint) : Transport {

    private val channel = Channel<TransportEvent>(Channel.UNLIMITED)
    override val events: Flow<TransportEvent> = channel.receiveAsFlow()

    private val socket: WebSocket = client.newWebSocket(
        Request.Builder().url(endpoint.url).build(),
        object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                channel.trySend(TransportEvent.Open)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                channel.trySend(TransportEvent.Text(text))
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = finish(reason)

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = finish(t.message)
        },
    )

    private fun finish(reason: String?) {
        channel.trySend(TransportEvent.Closed(reason))
        channel.close()
    }

    override fun send(text: String): Boolean = socket.send(text)

    override fun close() {
        if (!socket.close(1000, null)) socket.cancel()
    }
}

class LanTransportFactory(private val client: OkHttpClient) : TransportFactory {
    override fun open(endpoint: Endpoint): Transport = LanTransport(client, endpoint)
}
