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
    const val FS_LIST = "fs.list"
    const val FS_LISTING = "fs.listing"
    const val FS_THUMB = "fs.thumb"
    const val FS_THUMB_DATA = "fs.thumbData"
    const val FS_DOWNLOAD = "fs.download"
    const val FS_UPLOAD = "fs.upload"
    const val FS_UPLOAD_READY = "fs.uploadReady"
    const val FS_BEGIN = "fs.begin"
    const val FILE_ACK = "file.ack"
    const val FS_END = "fs.end"
    const val FS_DONE = "fs.done"
    const val FS_CANCEL = "fs.cancel"
    const val FS_DELETE = "fs.delete"
    const val FS_DELETED = "fs.deleted"
    const val FS_STATUS = "fs.status"
    const val MMS_RECEIVED = "mms.received"
    const val MMS_THUMB = "mms.thumb"
    const val MMS_THUMB_DATA = "mms.thumbData"
    const val MMS_PART = "mms.part"
    const val MMS_ATTACH = "mms.attach"
    const val MMS_SEND = "mms.send"
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

@Serializable
data class SmsSync(
    val sinceId: Long,
    val sinceTime: Long,
    val pendingIds: List<Long> = emptyList(),
    val sinceMmsId: Long = 0,
    val pendingMmsIds: List<Long> = emptyList(),
)

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
    /** "sms" or "mms"; SMS and MMS ids overlap, so the Mac keys on both. */
    val kind: String = "sms",
    /** MMS only: everyone in the conversation except this phone. */
    val participants: List<Participant> = emptyList(),
    /** MMS only: who sent an incoming message. */
    val sender: String? = null,
    val attachments: List<Attachment> = emptyList(),
)

@Serializable data class Participant(val address: String, val contactName: String? = null)

@Serializable
data class Attachment(
    val partId: Long,
    val mime: String,
    val name: String? = null,
    val size: Long,
    val width: Int? = null,
    val height: Int? = null,
)

/** Drives the Mac's notification for an incoming MMS; storage still comes from `sms.batch`. */
@Serializable
data class MmsReceived(
    val threadId: Long,
    val sender: String,
    val senderName: String? = null,
    val title: String,
    val text: String,
    val hasPhoto: Boolean,
)

@Serializable
data class DeviceStatus(
    val battery: Int,
    val charging: Boolean,
    val cellLevel: Int? = null,
    val wifiLevel: Int? = null,
    val wifiConnected: Boolean,
)

@Serializable data class FsList(val requestId: String, val path: String, val showHidden: Boolean = false)

@Serializable
data class FsEntry(val name: String, val isDir: Boolean, val size: Long, val modified: Long, val mime: String? = null)

@Serializable
data class FsListing(
    val requestId: String,
    val path: String,
    val entries: List<FsEntry> = emptyList(),
    val error: String? = null,
    /** Large folders arrive in pages; the last page has `done = true`. */
    val done: Boolean = true,
)

@Serializable data class FsThumb(val requestId: String, val path: String, val maxPx: Int = 256)

@Serializable data class FsThumbData(val requestId: String, val jpegBase64: String? = null, val error: String? = null)

@Serializable data class FsDownload(val transferId: String, val path: String)

@Serializable data class FsUpload(val transferId: String, val dir: String, val name: String, val size: Long)

@Serializable data class FsUploadReady(val transferId: String, val finalName: String)

@Serializable data class FsBegin(val transferId: String, val size: Long, val name: String)

@Serializable data class FileAck(val transferId: String, val received: Int)

@Serializable data class FsEnd(val transferId: String, val sha256: String)

@Serializable data class FsDone(val transferId: String, val ok: Boolean, val error: String? = null)

@Serializable data class FsCancel(val transferId: String)

@Serializable data class FsDelete(val requestId: String, val paths: List<String>)

@Serializable data class FsDeleteFailure(val path: String, val error: String)

@Serializable data class FsDeleted(val requestId: String, val failed: List<FsDeleteFailure> = emptyList())

@Serializable data class FsStatus(val allFilesAccess: Boolean)

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
