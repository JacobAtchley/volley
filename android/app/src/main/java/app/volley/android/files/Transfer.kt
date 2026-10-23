package app.volley.android.files

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Binary frame: 16-byte transfer id, then the chunk bytes. See docs/PROTOCOL.md. */
object ChunkFrame {
    const val CHUNK = 262_144
    private const val HEADER = 16

    fun encode(id: UUID, payload: ByteArray, len: Int = payload.size): ByteArray =
        ByteBuffer.allocate(HEADER + len).apply {
            putLong(id.mostSignificantBits)
            putLong(id.leastSignificantBits)
            put(payload, 0, len)
        }.array()

    fun decode(frame: ByteArray): Pair<UUID, ByteArray>? {
        if (frame.size < HEADER) return null
        val buf = ByteBuffer.wrap(frame)
        val id = UUID(buf.long, buf.long)
        return id to frame.copyOfRange(HEADER, frame.size)
    }
}

/**
 * Streams [input] as chunk frames, keeping at most [window] chunks unacknowledged so neither side buffers
 * a whole file. [sendFrame] returning false (socket queue full) keeps the chunk for the next [pump].
 */
class ChunkSender(
    val id: UUID,
    private val input: InputStream,
    private val sendFrame: (ByteArray) -> Boolean,
    private val window: Int = 8,
    private val chunk: Int = ChunkFrame.CHUNK,
) {
    private val digest = MessageDigest.getInstance("SHA-256")
    private var sent = 0
    private var acked = 0
    private var pending: ByteArray? = null
    private var eof = false
    private var hex: String? = null

    /** True once every chunk has been handed to the socket. */
    @Synchronized
    fun pump(): Boolean {
        while (sent - acked < window) {
            val frame = pending ?: nextFrame() ?: break
            if (!sendFrame(frame)) {
                pending = frame
                return false
            }
            pending = null
            sent++
        }
        return eof && pending == null
    }

    @Synchronized
    fun onAck(received: Int) {
        acked = maxOf(acked, received)
    }

    val done: Boolean
        @Synchronized get() = eof && pending == null && acked >= sent

    /** Releases the file (cancel, disconnect, or done). */
    @Synchronized
    fun close() = runCatching { input.close() }

    /** Hex SHA-256 of everything read; valid once [pump] has returned true. */
    val sha256Hex: String
        @Synchronized get() = hex ?: digest.digest().toHex().also { hex = it }

    private fun nextFrame(): ByteArray? {
        if (eof) return null
        val buf = ByteArray(chunk)
        var n = 0
        while (n < chunk) {
            val r = input.read(buf, n, chunk - n)
            if (r < 0) break
            n += r
        }
        if (n < chunk) {
            eof = true
            input.close()
        }
        if (n == 0) return null
        digest.update(buf, 0, n)
        return ChunkFrame.encode(id, buf, n)
    }
}

/** Writes incoming chunks to [output], acking the running count after each. */
class ChunkReceiver(val id: UUID, private val output: OutputStream, private val ack: (Int) -> Unit) {
    private val digest = MessageDigest.getInstance("SHA-256")
    private var received = 0

    @Synchronized
    fun onChunk(bytes: ByteArray) {
        output.write(bytes)
        digest.update(bytes)
        received++
        ack(received)
    }

    /** Releases the file without verifying (cancel, disconnect). */
    @Synchronized
    fun close() = runCatching { output.close() }

    /** Closes the output; true when the content matches [expectedSha256]. */
    @Synchronized
    fun finish(expectedSha256: String): Boolean {
        output.close()
        return digest.digest().toHex().equals(expectedSha256, ignoreCase = true)
    }
}

/** Transfers in flight on this connection, by id. */
class TransferRegistry {
    private val senders = ConcurrentHashMap<UUID, ChunkSender>()
    private val receivers = ConcurrentHashMap<UUID, ChunkReceiver>()

    fun add(sender: ChunkSender) = senders.put(sender.id, sender)

    fun add(receiver: ChunkReceiver) = receivers.put(receiver.id, receiver)

    fun sender(id: UUID): ChunkSender? = senders[id]

    fun receiver(id: UUID): ChunkReceiver? = receivers[id]

    fun remove(id: UUID) {
        senders.remove(id)
        receivers.remove(id)
    }

    fun clear() {
        senders.clear()
        receivers.clear()
    }
}

private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
