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
data class Envelope(val type: String, val id: String, val ts: Long, val body: JsonObject)

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
    const val SMS_SYNC = "sms.sync"
    const val SMS_BATCH = "sms.batch"
    const val DEVICE_STATUS = "device.status"
    const val NOTIFICATION_FILTER = "notification.filter"
    const val NOTIFICATION_SYNC = "notification.sync"
    const val NOTIFICATION_BATCH = "notification.batch"
}

@Serializable data class PairRequest(val deviceId: String, val deviceName: String, val code: String)

@Serializable
data class PairResult(val ok: Boolean, val macId: String = "", val macName: String = "", val token: String? = null)

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

@Serializable data class NotificationFilter(val excludedPackages: List<String> = emptyList())

@Serializable data class NotificationSync(val sinceTime: Long)

@Serializable
data class NotificationBatch(
    val notifications: List<NotificationPosted> = emptyList(),
    val activeKeys: List<String> = emptyList(),
    val done: Boolean,
)

@Serializable data class SmsReceived(val address: String, val body: String, val receivedAt: Long)

@Serializable
data class SmsSend(val requestId: String, val address: String, val body: String, val threadId: Long? = null)

@Serializable data class SmsSent(val requestId: String, val ok: Boolean, val error: String? = null)

@Serializable data class SmsSync(val sinceId: Long, val sinceTime: Long, val pendingIds: List<Long> = emptyList())

@Serializable data class SmsBatch(val messages: List<SmsRecord>, val done: Boolean)

@Serializable
data class SmsRecord(
    val id: Long,
    val threadId: Long,
    val address: String,
    val contactName: String? = null,
    val body: String,
    val date: Long,
    val outgoing: Boolean,
    val status: String,
)

@Serializable
data class DeviceStatus(
    val battery: Int,
    val charging: Boolean,
    val cellLevel: Int? = null,
    val wifiLevel: Int? = null,
    val wifiConnected: Boolean,
)

object Codec {
    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    inline fun <reified T> encode(type: String, body: T): String = json.encodeToString(
        Envelope.serializer(),
        Envelope(
            type = type,
            id = UUID.randomUUID().toString(),
            ts = System.currentTimeMillis(),
            body = json.encodeToJsonElement(body).jsonObject,
        ),
    )

    fun decode(text: String): Envelope? = runCatching { json.decodeFromString(Envelope.serializer(), text) }.getOrNull()
}

inline fun <reified T> Envelope.bodyAs(): T? = runCatching { Codec.json.decodeFromJsonElement<T>(body) }.getOrNull()
