package app.volley.android.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import java.util.UUID

/** Wire envelope. See docs/PROTOCOL.md. */
@Serializable
data class Envelope(
    val type: String,
    val id: String,
    val ts: Long,
    val body: JsonObject,
)

object MsgType {
    const val PAIR_REQUEST = "pair.request"
    const val PAIR_RESULT = "pair.result"
    const val HELLO = "hello"
    const val HELLO_OK = "hello.ok"
    const val NOTIFICATION_POSTED = "notification.posted"
    const val NOTIFICATION_REMOVED = "notification.removed"
    const val NOTIFICATION_DISMISS = "notification.dismiss"
    const val SMS_RECEIVED = "sms.received"
    const val SMS_SEND = "sms.send"
    const val SMS_SENT = "sms.sent"
}

@Serializable data class PairRequest(val deviceId: String, val deviceName: String, val code: String)
@Serializable data class PairResult(val ok: Boolean, val macId: String = "", val macName: String = "", val token: String? = null)
@Serializable data class Hello(val deviceId: String, val deviceName: String, val token: String)
@Serializable data class HelloOk(val macId: String, val macName: String)

@Serializable
data class NotificationPosted(
    val key: String,
    val pkg: String,
    val appName: String,
    val title: String,
    val text: String,
    val postedAt: Long,
)

@Serializable data class NotificationKey(val key: String)
@Serializable data class SmsReceived(val address: String, val body: String, val receivedAt: Long)
@Serializable data class SmsSend(val requestId: String, val address: String, val body: String)
@Serializable data class SmsSent(val requestId: String, val ok: Boolean, val error: String? = null)

object Codec {
    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    inline fun <reified T> encode(type: String, body: T): String =
        json.encodeToString(
            Envelope.serializer(),
            Envelope(
                type = type,
                id = UUID.randomUUID().toString(),
                ts = System.currentTimeMillis(),
                body = json.encodeToJsonElement(body).jsonObject,
            ),
        )

    fun decode(text: String): Envelope? =
        runCatching { json.decodeFromString(Envelope.serializer(), text) }.getOrNull()
}

inline fun <reified T> Envelope.bodyAs(): T? =
    runCatching { Codec.json.decodeFromJsonElement<T>(body) }.getOrNull()
