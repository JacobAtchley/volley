package app.volley.android.files

import app.volley.android.protocol.Codec
import app.volley.android.protocol.Envelope
import app.volley.android.protocol.FileAck
import app.volley.android.protocol.FsBegin
import app.volley.android.protocol.FsCancel
import app.volley.android.protocol.FsDone
import app.volley.android.protocol.FsDownload
import app.volley.android.protocol.FsEnd
import app.volley.android.protocol.FsList
import app.volley.android.protocol.FsListing
import app.volley.android.protocol.FsUpload
import app.volley.android.protocol.FsUploadReady
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.bodyAs
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class FileHandlersTest {
    @get:Rule val tmp = TemporaryFolder()

    private val root by lazy { tmp.newFolder("root") }
    private val sent = mutableListOf<Envelope>()
    private val binary = mutableListOf<ByteArray>()
    private var access = true
    private val scanned = mutableListOf<String>()
    private val active = mutableListOf<Boolean>()
    private val thumbSizes = mutableListOf<Int>()
    private val queuedWork = mutableListOf<Runnable>()
    private val handlers by lazy {
        FileHandlers(
            files = DiskFileService(StoragePaths(root)) { _, px ->
                thumbSizes += px
                byteArrayOf(1)
            },
            send = {
                sent += Codec.decode(it)!!
                true
            },
            sendBinary = {
                binary += it
                true
            },
            hasAccess = { access },
            onTransferActive = { active += it },
            scan = { scanned += it },
            chunk = 4,
            background = { queuedWork += it },
        )
    }

    private inline fun <reified T> deliver(type: String, body: T) =
        handlers.handle(Codec.decode(Codec.encode(type, body))!!)

    private inline fun <reified T> sentBodies(type: String): List<T> = sent.filter {
        it.type == type
    }.map { it.bodyAs<T>()!! }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") {
        "%02x".format(it)
    }

    @Test
    fun listReplyEchoesRequestId() {
        File(root, "Pictures").mkdir()
        deliver(MsgType.FS_LIST, FsList("r1", ""))
        val listing = sentBodies<FsListing>(MsgType.FS_LISTING).single()
        assertEquals("r1", listing.requestId)
        assertEquals(listOf("Pictures"), listing.entries.map { it.name })
    }

    @Test
    fun listWithoutAccessReturnsError() {
        access = false
        deliver(MsgType.FS_LIST, FsList("r1", ""))
        assertNotNull(sentBodies<FsListing>(MsgType.FS_LISTING).single().error)
    }

    @Test
    fun downloadSendsBeginChunksEndAfterAcks() {
        val data = ByteArray(10) { it.toByte() }
        File(root, "v.bin").writeBytes(data)
        val id = UUID.randomUUID()
        deliver(MsgType.FS_DOWNLOAD, FsDownload(id.toString(), "v.bin"))
        assertEquals(FsBegin(id.toString(), 10, "v.bin"), sentBodies<FsBegin>(MsgType.FS_BEGIN).single())
        assertEquals(3, binary.size)
        assertArrayEquals(data, binary.flatMap { ChunkFrame.decode(it)!!.second.toList() }.toByteArray())
        assertEquals(sha(data), sentBodies<FsEnd>(MsgType.FS_END).single().sha256)
        assertEquals(listOf(true), active)
        deliver(MsgType.FILE_ACK, FileAck(id.toString(), 3))
        deliver(MsgType.FS_DONE, FsDone(id.toString(), ok = true))
        assertEquals(listOf(true, false), active)
    }

    @Test
    fun downloadOfMissingFileRepliesDoneFalse() {
        val id = UUID.randomUUID().toString()
        deliver(MsgType.FS_DOWNLOAD, FsDownload(id, "nope.bin"))
        val done = sentBodies<FsDone>(MsgType.FS_DONE).single()
        assertEquals(id, done.transferId)
        assertFalse(done.ok)
    }

    private fun upload(name: String, data: ByteArray, sha: String = sha(data)): Pair<String, FsDone> {
        val id = UUID.randomUUID()
        deliver(MsgType.FS_UPLOAD, FsUpload(id.toString(), "Download", name, data.size.toLong()))
        val ready = sentBodies<FsUploadReady>(MsgType.FS_UPLOAD_READY).last()
        data.toList().chunked(4).forEach { handlers.onBinary(ChunkFrame.encode(id, it.toByteArray())) }
        deliver(MsgType.FS_END, FsEnd(id.toString(), sha))
        return ready.finalName to sentBodies<FsDone>(MsgType.FS_DONE).last()
    }

    @Test
    fun uploadReadyThenChunksThenDoneOk() {
        File(root, "Download").mkdir()
        File(root, "Download/a.txt").writeText("old")
        val data = "hello world".toByteArray()
        val (name, done) = upload("a.txt", data)
        assertEquals("a (1).txt", name)
        assertTrue(done.ok)
        assertArrayEquals(data, File(root, "Download/a (1).txt").readBytes())
        assertEquals(listOf(1, 2, 3), sentBodies<FileAck>(MsgType.FILE_ACK).map { it.received })
        assertEquals(listOf("Download/a (1).txt"), scanned)
    }

    @Test
    fun uploadShaMismatchDiscards() {
        val (_, done) = upload("b.txt", "data".toByteArray(), sha = "00")
        assertFalse(done.ok)
        assertFalse(File(root, "Download/b.txt").exists())
    }

    @Test
    fun cancelStopsAndDiscards() {
        val id = UUID.randomUUID()
        deliver(MsgType.FS_UPLOAD, FsUpload(id.toString(), "Download", "c.txt", 8))
        handlers.onBinary(ChunkFrame.encode(id, byteArrayOf(1, 2, 3, 4)))
        deliver(MsgType.FS_CANCEL, FsCancel(id.toString()))
        assertFalse(File(root, "Download/c.txt").exists())
        handlers.onBinary(ChunkFrame.encode(id, byteArrayOf(5))) // late chunk is ignored
        assertFalse(File(root, "Download/c.txt").exists())
    }

    @Test
    fun disconnectDiscardsPartialUpload() {
        val id = UUID.randomUUID()
        deliver(MsgType.FS_UPLOAD, FsUpload(id.toString(), "Download", "d.txt", 8))
        handlers.onBinary(ChunkFrame.encode(id, byteArrayOf(1, 2, 3, 4)))
        handlers.onDisconnect()
        assertFalse(File(root, "Download/d.txt").exists())
        assertEquals(listOf(true, false), active)
    }

    @Test
    fun malformedTransferIdDoesNotThrow() {
        deliver(MsgType.FS_DOWNLOAD, FsDownload("not-a-uuid", "x"))
        deliver(MsgType.FILE_ACK, FileAck("nope", 1))
        assertTrue(sent.none { it.type == MsgType.FS_BEGIN })
    }

    @Test
    fun zeroByteUploadCompletes() {
        val (name, done) = upload("empty.txt", ByteArray(0))
        assertTrue(done.ok)
        assertTrue(File(root, "Download/$name").exists())
    }

    @Test
    fun cancelClosesDownloadStream() {
        var closed = false
        val disk = DiskFileService(StoragePaths(root)) { _, _ -> null }
        val tracking = object : FileService by disk {
            override fun openRead(path: String) = disk.openRead(path).map { (input, size) ->
                object : java.io.FilterInputStream(input) {
                    override fun close() {
                        closed = true
                        super.close()
                    }
                } to size
            }
        }
        val h = FileHandlers(tracking, send = { true }, sendBinary = { true }, hasAccess = { true }, chunk = 4)
        File(root, "big.bin").writeBytes(ByteArray(100))
        val id = UUID.randomUUID().toString()
        h.handle(Codec.decode(Codec.encode(MsgType.FS_DOWNLOAD, FsDownload(id, "big.bin")))!!)
        assertFalse(closed)
        h.handle(Codec.decode(Codec.encode(MsgType.FS_CANCEL, FsCancel(id)))!!)
        assertTrue(closed)
    }

    @Test
    fun thumbnailsRunOffTheReceiveThreadWithCappedSize() {
        File(root, "a.jpg").writeBytes(ByteArray(1))
        deliver(MsgType.FS_THUMB, app.volley.android.protocol.FsThumb("t1", "a.jpg", maxPx = 5_000))
        assertTrue("nothing sent until the background work runs", sent.none { it.type == MsgType.FS_THUMB_DATA })
        queuedWork.forEach(Runnable::run)
        assertEquals(listOf(512), thumbSizes)
        assertEquals(1, sent.count { it.type == MsgType.FS_THUMB_DATA })
    }

    @Test
    fun listPagesOf500() {
        val dir = File(root, "DCIM/Camera").apply { mkdirs() }
        repeat(1_201) { File(dir, "IMG_%04d.jpg".format(it)).writeBytes(ByteArray(1)) }
        deliver(MsgType.FS_LIST, FsList("r1", "DCIM/Camera"))
        val pages = sentBodies<FsListing>(MsgType.FS_LISTING)
        assertEquals(listOf(500, 500, 201), pages.map { it.entries.size })
        assertEquals(listOf(false, false, true), pages.map { it.done })
        assertEquals(1_201, pages.flatMap { it.entries }.map { it.name }.toSet().size)
    }

    @Test
    fun emptyFolderSendsOneDonePage() {
        File(root, "Empty").mkdir()
        deliver(MsgType.FS_LIST, FsList("r1", "Empty"))
        val page = sentBodies<FsListing>(MsgType.FS_LISTING).single()
        assertTrue(page.done)
        assertTrue(page.entries.isEmpty())
    }

    @Test
    fun downloadEchoesTheMacsTransferIdExactly() {
        File(root, "v.bin").writeBytes(ByteArray(3))
        val macId = UUID.randomUUID().toString().uppercase()
        deliver(MsgType.FS_DOWNLOAD, FsDownload(macId, "v.bin"))
        assertEquals(listOf(macId), sentBodies<FsEnd>(MsgType.FS_END).map { it.transferId })
    }
}
