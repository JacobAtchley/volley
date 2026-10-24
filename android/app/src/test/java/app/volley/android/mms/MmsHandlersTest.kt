package app.volley.android.mms

import app.volley.android.files.ChunkFrame
import app.volley.android.files.DiskFileService
import app.volley.android.files.FileHandlers
import app.volley.android.files.StoragePaths
import app.volley.android.protocol.Codec
import app.volley.android.protocol.Envelope
import app.volley.android.protocol.FileAck
import app.volley.android.protocol.FsBegin
import app.volley.android.protocol.FsDone
import app.volley.android.protocol.FsEnd
import app.volley.android.protocol.FsUploadReady
import app.volley.android.protocol.MmsAttach
import app.volley.android.protocol.MmsPartRequest
import app.volley.android.protocol.MmsSend
import app.volley.android.protocol.MmsThumb
import app.volley.android.protocol.MmsThumbData
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.SmsSent
import app.volley.android.protocol.bodyAs
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MmsHandlersTest {
    @get:Rule val tmp = TemporaryFolder()

    private val sent = mutableListOf<Envelope>()
    private val binary = mutableListOf<ByteArray>()
    private val thumbWork = mutableListOf<Runnable>()
    private val sendWork = mutableListOf<Runnable>()

    private class SendCall(val to: List<String>, val text: String?, val images: List<ByteArray>)

    private val sendCalls = mutableListOf<SendCall>()
    private var sendResult: Pair<Boolean, String?> = true to null
    private var senderThrows = false
    private var attachDir: File? = null

    private val parts = object : MmsParts {
        override fun open(partId: Long) = if (partId == 42L) {
            Result.success(PartStream(ByteArrayInputStream("photo-bytes".toByteArray()), 11, "IMG_42.jpg"))
        } else {
            Result.failure(IllegalArgumentException("No such part"))
        }

        override fun thumbnail(partId: Long, maxPx: Int) = Result.success(byteArrayOf(maxPx.toByte()))
    }

    private val files by lazy {
        FileHandlers(
            files = DiskFileService(StoragePaths(tmp.newFolder("root"))) { _, _ -> null },
            send = ::record,
            sendBinary = {
                binary += it
                true
            },
            hasAccess = { true },
            chunk = 4,
        )
    }

    private val handlers by lazy {
        MmsHandlers(
            parts = parts,
            transfers = files,
            sender = { _, to, text, images, onResult ->
                if (senderThrows) error("decoder crashed")
                sendCalls += SendCall(to, text, images.map { it.readBytes() })
                onResult(sendResult.first, sendResult.second)
            },
            attachDir = attachDir ?: tmp.newFolder("mms-out"),
            send = ::record,
            thumbs = { thumbWork += it },
            sends = { sendWork += it },
            ownNumber = { "+1 (555) 999-0000" },
        )
    }

    private fun record(frame: String): Boolean {
        sent += Codec.decode(frame)!!
        return true
    }

    private inline fun <reified T> deliver(type: String, body: T) {
        val env = Codec.decode(Codec.encode(type, body))!!
        if (env.type in handlers.types) handlers.handle(env) else files.handle(env)
    }

    private inline fun <reified T> bodies(type: String) = sent.filter { it.type == type }.map { it.bodyAs<T>()!! }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") {
        "%02x".format(it)
    }

    /** Uploads [data] the way the Mac does; returns the transfer id. */
    private fun attach(data: ByteArray, name: String = "photo.jpg"): String {
        val id = UUID.randomUUID()
        deliver(MsgType.MMS_ATTACH, MmsAttach(id.toString().uppercase(), name, data.size.toLong()))
        data.toList().chunked(4).forEach { files.onBinary(ChunkFrame.encode(id, it.toByteArray())) }
        deliver(MsgType.FS_END, FsEnd(id.toString().uppercase(), sha(data)))
        return id.toString().uppercase()
    }

    @Test
    fun thumbRequestRunsInBackground() {
        deliver(MsgType.MMS_THUMB, MmsThumb("r1", partId = 42, maxPx = 2000))
        assertTrue(bodies<MmsThumbData>(MsgType.MMS_THUMB_DATA).isEmpty())
        thumbWork.single().run()
        val data = bodies<MmsThumbData>(MsgType.MMS_THUMB_DATA).single()
        assertEquals("r1", data.requestId)
        // Clamped to 512 px.
        assertArrayEquals(byteArrayOf(512.toByte()), java.util.Base64.getDecoder().decode(data.jpegBase64))
    }

    @Test
    fun partDownloadUsesTransferFlow() {
        val id = UUID.randomUUID().toString()
        deliver(MsgType.MMS_PART, MmsPartRequest(id, partId = 42))
        assertEquals(FsBegin(id, 11, "IMG_42.jpg"), bodies<FsBegin>(MsgType.FS_BEGIN).single())
        deliver(MsgType.FILE_ACK, FileAck(id, binary.size))
        val received = binary.flatMap { ChunkFrame.decode(it)!!.second.toList() }.toByteArray()
        assertEquals("photo-bytes", String(received))
        assertEquals(sha("photo-bytes".toByteArray()), bodies<FsEnd>(MsgType.FS_END).single().sha256)
    }

    @Test
    fun missingPartFailsTheTransfer() {
        val id = UUID.randomUUID().toString()
        deliver(MsgType.MMS_PART, MmsPartRequest(id, partId = 7))
        assertEquals(FsDone(id, ok = false, error = "No such part"), bodies<FsDone>(MsgType.FS_DONE).single())
    }

    @Test
    fun attachThenSendPassesFilesToSender() {
        val photo = "jpeg-data-123".toByteArray()
        val id = attach(photo)
        assertEquals(id, bodies<FsUploadReady>(MsgType.FS_UPLOAD_READY).single().transferId)
        assertEquals(listOf(true), bodies<FsDone>(MsgType.FS_DONE).map { it.ok })

        deliver(MsgType.MMS_SEND, MmsSend("s1", threadId = 3, addresses = listOf("+1555", "+1777"), "hi", listOf(id)))
        assertTrue(sendCalls.isEmpty()) // decoding photos happens off the receive thread
        sendWork.single().run()

        val call = sendCalls.single()
        assertEquals(listOf("+1555", "+1777"), call.to)
        assertEquals("hi", call.text)
        assertArrayEquals(photo, call.images.single())
        assertEquals(SmsSent("s1", ok = true), bodies<SmsSent>(MsgType.SMS_SENT).single())
    }

    @Test
    fun sendFailureRepliesSmsSentFalse() {
        sendResult = false to "Carrier rejected the MMS (status 0xE0)"
        deliver(MsgType.MMS_SEND, MmsSend("s2", threadId = 3, addresses = listOf("+1555"), "hi"))
        sendWork.single().run()
        assertEquals(
            SmsSent("s2", ok = false, error = "Carrier rejected the MMS (status 0xE0)"),
            bodies<SmsSent>(MsgType.SMS_SENT).single(),
        )
    }

    @Test
    fun unknownAttachmentIdFails() {
        deliver(
            MsgType.MMS_SEND,
            MmsSend("s3", threadId = 3, addresses = listOf("+1555"), attachments = listOf("nope")),
        )
        sendWork.forEach(Runnable::run)
        assertTrue(sendCalls.isEmpty())
        assertEquals(
            SmsSent("s3", ok = false, error = "A photo didn't reach the phone; try again"),
            bodies<SmsSent>(MsgType.SMS_SENT).single(),
        )
    }

    @Test
    fun corruptAttachmentIsNotKept() {
        val id = UUID.randomUUID()
        deliver(MsgType.MMS_ATTACH, MmsAttach(id.toString(), "p.jpg", 4))
        files.onBinary(ChunkFrame.encode(id, byteArrayOf(1, 2, 3, 4)))
        deliver(MsgType.FS_END, FsEnd(id.toString(), "00"))
        assertEquals(listOf(false), bodies<FsDone>(MsgType.FS_DONE).map { it.ok })
        assertTrue(File(tmp.root, "mms-out").listFiles()!!.isEmpty())
    }

    @Test
    fun sendLeavesOutThisPhonesOwnNumber() {
        deliver(MsgType.MMS_SEND, MmsSend("s4", threadId = 3, addresses = listOf("+1555", "5559990000", "+1777"), "hi"))
        sendWork.single().run()
        assertEquals(listOf("+1555", "+1777"), sendCalls.single().to)
    }

    @Test
    fun attachFailureRepliesInsteadOfDroppingTheConnection() {
        attachDir = tmp.newFile("not-a-folder")
        val id = UUID.randomUUID().toString()
        deliver(MsgType.MMS_ATTACH, MmsAttach(id, "p.jpg", 4))
        assertEquals(listOf(id to false), bodies<FsDone>(MsgType.FS_DONE).map { it.transferId to it.ok })
    }

    @Test
    fun senderCrashRepliesNotSent() {
        senderThrows = true
        deliver(MsgType.MMS_SEND, MmsSend("s5", threadId = 3, addresses = listOf("+1555"), "hi"))
        sendWork.single().run()
        assertEquals(listOf(false), bodies<SmsSent>(MsgType.SMS_SENT).map { it.ok })
    }
}
