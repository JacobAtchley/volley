package app.volley.android.mms

import app.volley.android.files.Transfers
import app.volley.android.protocol.Codec
import app.volley.android.protocol.Envelope
import app.volley.android.protocol.FsDone
import app.volley.android.protocol.MmsAttach
import app.volley.android.protocol.MmsPartRequest
import app.volley.android.protocol.MmsSend
import app.volley.android.protocol.MmsThumb
import app.volley.android.protocol.MmsThumbData
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.SmsSent
import app.volley.android.protocol.bodyAs
import java.io.File
import java.io.InputStream
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class PartStream(val input: InputStream, val size: Long, val name: String?)

/** Reads MMS parts (photos, vCards…) from the phone's MMS store. */
interface MmsParts {
    fun open(partId: Long): Result<PartStream>
    fun thumbnail(partId: Long, maxPx: Int): Result<ByteArray>
}

fun interface MmsSending {
    fun send(
        requestId: String,
        to: List<String>,
        text: String?,
        images: List<File>,
        onResult: (Boolean, String?) -> Unit,
    )
}

/**
 * Answers the Mac's `mms.*` requests: thumbnails and downloads of MMS parts, photo uploads for a reply, and
 * sending. Thumbnails run on [thumbs] and sends on [sends] (photo decoding is slow), so texts keep flowing.
 */
class MmsHandlers(
    private val parts: MmsParts,
    private val transfers: Transfers,
    private val sender: MmsSending,
    private val attachDir: File,
    private val send: (String) -> Boolean,
    private val thumbs: (Runnable) -> Unit,
    private val sends: (Runnable) -> Unit,
) {
    /** Uploaded photos waiting for their `mms.send`, by transfer id. */
    private val attachments = ConcurrentHashMap<UUID, File>()

    val types = listOf(MsgType.MMS_THUMB, MsgType.MMS_PART, MsgType.MMS_ATTACH, MsgType.MMS_SEND)

    fun handle(env: Envelope) {
        when (env.type) {
            MsgType.MMS_THUMB -> env.bodyAs<MmsThumb>()?.let(::thumb)
            MsgType.MMS_PART -> env.bodyAs<MmsPartRequest>()?.let(::part)
            MsgType.MMS_ATTACH -> env.bodyAs<MmsAttach>()?.let(::attach)
            MsgType.MMS_SEND -> env.bodyAs<MmsSend>()?.let(::sendMms)
        }
    }

    /** The Mac went away: drop photos that were never sent. */
    fun onDisconnect() {
        attachments.values.forEach(File::delete)
        attachments.clear()
    }

    private fun thumb(req: MmsThumb) = thumbs {
        val data = parts.thumbnail(req.partId, req.maxPx.coerceIn(1, MAX_THUMB_PX)).fold(
            { MmsThumbData(req.requestId, Base64.getEncoder().encodeToString(it)) },
            { MmsThumbData(req.requestId, error = it.message ?: "No preview") },
        )
        send(Codec.encode(MsgType.MMS_THUMB_DATA, data))
    }

    private fun part(req: MmsPartRequest) {
        parts.open(req.partId).fold(
            { transfers.downloadStream(req.transferId, it.name ?: "part-${req.partId}", it.size, it.input) },
            { send(Codec.encode(MsgType.FS_DONE, FsDone(req.transferId, ok = false, error = it.message))) },
        )
    }

    private fun attach(req: MmsAttach) {
        val id = uuid(req.transferId) ?: return
        attachDir.mkdirs()
        val file = File(attachDir, "$id-${req.name.substringAfterLast('/')}")
        transfers.receiveUpload(req.transferId, req.name, file.outputStream()) { ok ->
            if (ok) attachments[id] = file else file.delete()
        }
    }

    private fun sendMms(req: MmsSend) {
        val files = req.attachments.map { id -> uuid(id)?.let(attachments::remove) }
        if (files.any { it == null }) {
            files.filterNotNull().forEach(File::delete)
            reply(req.requestId, false, "A photo didn't reach the phone; try again")
            return
        }
        val images = files.filterNotNull()
        sends {
            sender.send(req.requestId, req.addresses, req.text?.takeIf { it.isNotEmpty() }, images) { ok, error ->
                images.forEach(File::delete)
                reply(req.requestId, ok, error)
            }
        }
    }

    private fun reply(requestId: String, ok: Boolean, error: String?) =
        send(Codec.encode(MsgType.SMS_SENT, SmsSent(requestId, ok, error)))

    private fun uuid(value: String): UUID? = runCatching { UUID.fromString(value) }.getOrNull()

    private companion object {
        const val MAX_THUMB_PX = 512
    }
}
