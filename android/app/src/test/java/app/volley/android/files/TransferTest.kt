package app.volley.android.files

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID

class TransferTest {
    private val id = UUID.fromString("00112233-4455-6677-8899-aabbccddeeff")

    private fun sha(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test
    fun frameRoundTrip() {
        val frame = ChunkFrame.encode(id, byteArrayOf(1, 2, 3))
        // Shared test vector with the Mac (TransferTests.testInteropWithAndroidFraming).
        assertEquals("00112233445566778899aabbccddeeff010203", frame.joinToString("") { "%02x".format(it) })
        val (decodedId, payload) = ChunkFrame.decode(frame)!!
        assertEquals(id, decodedId)
        assertArrayEquals(byteArrayOf(1, 2, 3), payload)
    }

    @Test
    fun decodeRejectsShortFrame() = assertNull(ChunkFrame.decode(ByteArray(15)))

    @Test
    fun senderRespectsWindow() {
        val frames = mutableListOf<ByteArray>()
        val sender =
            ChunkSender(id, ByteArrayInputStream(ByteArray(20 * 4)), {
                frames += it
                true
            }, window = 8, chunk = 4)
        assertFalse(sender.pump())
        assertEquals(8, frames.size)
        sender.onAck(3)
        assertFalse(sender.pump())
        assertEquals(11, frames.size)
    }

    @Test
    fun senderFinishesAfterAllAcked() {
        val data = ByteArray(10) { it.toByte() }
        val frames = mutableListOf<ByteArray>()
        val sender = ChunkSender(id, ByteArrayInputStream(data), {
            frames += it
            true
        }, window = 8, chunk = 4)
        assertTrue(sender.pump())
        assertEquals(listOf(4, 4, 2), frames.map { ChunkFrame.decode(it)!!.second.size })
        assertFalse(sender.done)
        sender.onAck(3)
        assertTrue(sender.done)
        assertEquals(sha(data), sender.sha256Hex)
    }

    @Test
    fun senderStopsWhenSocketQueueIsFull() {
        var accept = false
        val sender = ChunkSender(id, ByteArrayInputStream(ByteArray(8)), { accept }, window = 8, chunk = 4)
        assertFalse(sender.pump())
        accept = true
        assertTrue(sender.pump())
    }

    @Test
    fun receiverAcksCumulatively() {
        val acks = mutableListOf<Int>()
        val out = ByteArrayOutputStream()
        val receiver = ChunkReceiver(id, out) { acks += it }
        listOf(byteArrayOf(1), byteArrayOf(2), byteArrayOf(3)).forEach(receiver::onChunk)
        assertEquals(listOf(1, 2, 3), acks)
        assertArrayEquals(byteArrayOf(1, 2, 3), out.toByteArray())
    }

    @Test
    fun receiverVerifiesSha() {
        val good = ChunkReceiver(id, ByteArrayOutputStream()) {}
        good.onChunk(byteArrayOf(1, 2))
        assertTrue(good.finish(sha(byteArrayOf(1, 2))))
        val bad = ChunkReceiver(id, ByteArrayOutputStream()) {}
        bad.onChunk(byteArrayOf(1, 2))
        assertFalse(bad.finish(sha(byteArrayOf(9))))
    }

    @Test
    fun zeroByteFileCompletes() {
        val frames = mutableListOf<ByteArray>()
        val sender = ChunkSender(id, ByteArrayInputStream(ByteArray(0)), {
            frames += it
            true
        })
        assertTrue(sender.pump())
        assertTrue(frames.isEmpty())
        assertTrue(sender.done)
        assertEquals(sha(ByteArray(0)), sender.sha256Hex)
        assertTrue(ChunkReceiver(id, ByteArrayOutputStream()) {}.finish(sha(ByteArray(0))))
    }

    @Test
    fun ackForUnknownTransferIgnored() {
        val registry = TransferRegistry()
        assertNull(registry.sender(UUID.randomUUID()))
        assertNull(registry.receiver(UUID.randomUUID()))
    }
}
