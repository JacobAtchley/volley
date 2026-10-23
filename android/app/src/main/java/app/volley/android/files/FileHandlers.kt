package app.volley.android.files

import app.volley.android.protocol.Codec
import app.volley.android.protocol.Envelope
import app.volley.android.protocol.FileAck
import app.volley.android.protocol.FsBegin
import app.volley.android.protocol.FsCancel
import app.volley.android.protocol.FsDelete
import app.volley.android.protocol.FsDeleteFailure
import app.volley.android.protocol.FsDeleted
import app.volley.android.protocol.FsDone
import app.volley.android.protocol.FsDownload
import app.volley.android.protocol.FsEnd
import app.volley.android.protocol.FsList
import app.volley.android.protocol.FsListing
import app.volley.android.protocol.FsStatus
import app.volley.android.protocol.FsThumb
import app.volley.android.protocol.FsThumbData
import app.volley.android.protocol.FsUpload
import app.volley.android.protocol.FsUploadReady
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.bodyAs
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Answers the Mac's `fs.*` requests and runs file transfers in both directions. Everything runs on the
 * session's receive thread; transfers are paced by `file.ack`, so no extra threads are needed.
 */
class FileHandlers(
    private val files: FileService,
    private val send: (String) -> Boolean,
    private val sendBinary: (ByteArray) -> Boolean,
    private val hasAccess: () -> Boolean,
    private val onTransferActive: (Boolean) -> Unit = {},
    private val scan: (String) -> Unit = {},
    private val chunk: Int = ChunkFrame.CHUNK,
    private val background: (Runnable) -> Unit = { it.run() },
) {
    private val registry = TransferRegistry()
    private val endSent = ConcurrentHashMap.newKeySet<UUID>()

    /** Upload id → path being written, so cancels and disconnects can delete partial files. */
    private val uploads = ConcurrentHashMap<UUID, String>()
    private val activeIds = ConcurrentHashMap.newKeySet<UUID>()

    val types = listOf(
        MsgType.FS_LIST, MsgType.FS_THUMB, MsgType.FS_DELETE, MsgType.FS_DOWNLOAD, MsgType.FS_UPLOAD,
        MsgType.FILE_ACK, MsgType.FS_END, MsgType.FS_DONE, MsgType.FS_CANCEL,
    )

    fun statusFrame(): String = Codec.encode(MsgType.FS_STATUS, FsStatus(hasAccess()))

    /** One bad request (malformed id, disk full…) must not take down the connection, texts included. */
    fun handle(env: Envelope) {
        try {
            dispatch(env)
        } catch (e: Exception) {
            val id = runCatching { env.body["transferId"]?.toString()?.trim('"') }.getOrNull()
            if (id != null) failTransfer(id, e.message ?: "Phone error")
        }
    }

    private fun dispatch(env: Envelope) {
        when (env.type) {
            MsgType.FS_LIST -> env.bodyAs<FsList>()?.let(::list)
            MsgType.FS_THUMB -> env.bodyAs<FsThumb>()?.let(::thumb)
            MsgType.FS_DELETE -> env.bodyAs<FsDelete>()?.let(::delete)
            MsgType.FS_DOWNLOAD -> env.bodyAs<FsDownload>()?.let(::download)
            MsgType.FS_UPLOAD -> env.bodyAs<FsUpload>()?.let(::upload)
            MsgType.FILE_ACK -> env.bodyAs<FileAck>()?.let(::ack)
            MsgType.FS_END -> env.bodyAs<FsEnd>()?.let(::end)
            MsgType.FS_DONE -> env.bodyAs<FsDone>()?.let { done -> uuid(done.transferId)?.let(::finished) }
            MsgType.FS_CANCEL -> env.bodyAs<FsCancel>()?.let { c -> uuid(c.transferId)?.let(::cancel) }
        }
    }

    fun onBinary(bytes: ByteArray) {
        val (id, payload) = ChunkFrame.decode(bytes) ?: return
        val receiver = registry.receiver(id) ?: return
        try {
            receiver.onChunk(payload)
        } catch (e: Exception) {
            failTransfer(id.toString(), e.message ?: "Couldn't write")
        }
    }

    /** Ends a transfer after a phone-side error and tells the Mac why. */
    private fun failTransfer(transferId: String, message: String) {
        send(Codec.encode(MsgType.FS_DONE, FsDone(transferId, ok = false, error = message)))
        uuid(transferId)?.let(::cancel)
    }

    /** The Mac went away: abandon every transfer and delete partial uploads. */
    fun onDisconnect() {
        activeIds.forEach(::closeStreams)
        uploads.values.forEach(files::discard)
        uploads.clear()
        registry.clear()
        endSent.clear()
        if (activeIds.isNotEmpty()) {
            activeIds.clear()
            onTransferActive(false)
        }
    }

    private fun list(req: FsList) {
        val result = if (hasAccess()) files.list(req.path, req.showHidden) else Result.failure(noAccess())
        val entries = result.getOrElse {
            send(
                Codec.encode(
                    MsgType.FS_LISTING,
                    FsListing(
                        req.requestId,
                        req.path,
                        error =
                        it.message ?: "Couldn't list",
                    ),
                ),
            )
            return
        }
        // Pages, so the Mac can show the first screen of a huge folder straight away.
        val pages = entries.chunked(LIST_PAGE).ifEmpty { listOf(emptyList()) }
        pages.forEachIndexed { i, page ->
            send(
                Codec.encode(MsgType.FS_LISTING, FsListing(req.requestId, req.path, page, done = i == pages.lastIndex)),
            )
        }
    }

    /** Thumbnails are slow; make them off the receive thread so texts and transfers keep flowing. */
    private fun thumb(req: FsThumb) = background {
        val data = files.thumbnail(req.path, req.maxPx.coerceIn(1, MAX_THUMB_PX)).fold(
            { FsThumbData(req.requestId, Base64.getEncoder().encodeToString(it)) },
            { FsThumbData(req.requestId, error = it.message) },
        )
        send(Codec.encode(MsgType.FS_THUMB_DATA, data))
    }

    private fun delete(req: FsDelete) {
        val failed = if (hasAccess()) files.delete(req.paths) else req.paths.map { FsDeleteFailure(it, "No access") }
        req.paths.filter { p -> failed.none { it.path == p } }.forEach(scan)
        send(Codec.encode(MsgType.FS_DELETED, FsDeleted(req.requestId, failed)))
    }

    private fun download(req: FsDownload) {
        val id = uuid(req.transferId) ?: return
        val opened = if (hasAccess()) files.openRead(req.path) else Result.failure(noAccess())
        val (input, size) = opened.getOrElse {
            send(Codec.encode(MsgType.FS_DONE, FsDone(req.transferId, ok = false, error = it.message)))
            return
        }
        started(id)
        send(Codec.encode(MsgType.FS_BEGIN, FsBegin(req.transferId, size, req.path.substringAfterLast('/'))))
        val sender = ChunkSender(id, input, sendBinary, chunk = chunk)
        registry.add(sender)
        pump(sender)
    }

    private fun upload(req: FsUpload) {
        val id = uuid(req.transferId) ?: return
        val created = if (hasAccess()) files.createForUpload(req.dir, req.name) else Result.failure(noAccess())
        val (finalName, output) = created.getOrElse {
            send(Codec.encode(MsgType.FS_DONE, FsDone(req.transferId, ok = false, error = it.message)))
            return
        }
        started(id)
        uploads[id] = listOf(req.dir, finalName).filter { it.isNotEmpty() }.joinToString("/")
        registry.add(
            ChunkReceiver(id, output) { received ->
                send(Codec.encode(MsgType.FILE_ACK, FileAck(req.transferId, received)))
            },
        )
        send(Codec.encode(MsgType.FS_UPLOAD_READY, FsUploadReady(req.transferId, finalName)))
    }

    private fun ack(req: FileAck) {
        val sender = uuid(req.transferId)?.let(registry::sender) ?: return
        sender.onAck(req.received)
        pump(sender)
    }

    private fun pump(sender: ChunkSender) {
        if (sender.pump() && endSent.add(sender.id)) {
            send(Codec.encode(MsgType.FS_END, FsEnd(sender.id.toString(), sender.sha256Hex)))
        }
    }

    /** End of an upload: verify, then keep or discard. */
    private fun end(req: FsEnd) {
        val id = uuid(req.transferId) ?: return
        val receiver = registry.receiver(id) ?: return
        val path = uploads.remove(id)
        val ok = receiver.finish(req.sha256)
        if (ok) path?.let(scan) else path?.let(files::discard)
        val error = if (ok) null else "Checksum mismatch"
        send(Codec.encode(MsgType.FS_DONE, FsDone(req.transferId, ok, error)))
        finished(id)
    }

    private fun cancel(id: UUID) {
        uploads.remove(id)?.let(files::discard)
        finished(id)
    }

    private fun started(id: UUID) {
        if (activeIds.isEmpty()) onTransferActive(true)
        activeIds.add(id)
    }

    private fun finished(id: UUID) {
        closeStreams(id)
        registry.remove(id)
        endSent.remove(id)
        if (activeIds.remove(id) && activeIds.isEmpty()) onTransferActive(false)
    }

    private fun closeStreams(id: UUID) {
        registry.sender(id)?.close()
        registry.receiver(id)?.close()
    }

    private fun uuid(value: String): UUID? = runCatching { UUID.fromString(value) }.getOrNull()

    private fun noAccess() = IllegalStateException("Volley needs All files access on the phone")

    private companion object {
        const val MAX_THUMB_PX = 512
        const val LIST_PAGE = 500
    }
}
