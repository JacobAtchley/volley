package app.volley.android.sms

import app.volley.android.protocol.Codec
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.SmsBatch
import app.volley.android.protocol.SmsRecord

/** One row of the SMS provider. [type] is `Telephony.Sms.TYPE_*`. */
data class SmsRow(
    val id: Long,
    val threadId: Long,
    val address: String,
    val body: String,
    val date: Long,
    val type: Int,
)

/** Maps a provider row to the wire record; null for rows we don't sync (drafts and unknown types). */
fun SmsRow.toRecord(contactName: String?): SmsRecord? {
    val (status, outgoing) = when (type) {
        1 -> "received" to false
        2 -> "sent" to true
        4, 6 -> "pending" to true
        5 -> "failed" to true
        else -> return null
    }
    return SmsRecord(id, threadId, address, contactName, body, date, outgoing, status)
}

/** Reads SMS rows, ordered by ascending `_id`. */
interface SmsSource {
    fun since(sinceId: Long, sinceTime: Long): List<SmsRow>
    fun byIds(ids: Collection<Long>): List<SmsRow>
}

fun interface ContactNames {
    fun lookup(address: String): String?
}

/**
 * Answers the Mac's `sms.sync` and then streams changes as `sms.batch` frames.
 * Nothing is sent on change until the Mac has asked for a sync, so we never guess its cursor.
 */
class SmsSyncer(
    private val source: SmsSource,
    private val names: ContactNames,
    private val send: (String) -> Unit,
) {
    private var cursor: Long? = null
    private var floor = 0L
    private var pendingIds = emptySet<Long>()

    @Synchronized
    fun syncFrom(sinceId: Long, sinceTime: Long) {
        val records = toRecords(source.since(sinceId, sinceTime))
        val chunks = records.chunked(CHUNK).ifEmpty { listOf(emptyList()) }
        chunks.forEachIndexed { i, chunk -> sendBatch(chunk, done = i == chunks.lastIndex) }
        cursor = maxOf(sinceId, records.maxOfOrNull { it.id } ?: 0)
        floor = sinceTime
        pendingIds = records.pendingIds()
    }

    @Synchronized
    fun onChanged() {
        val from = cursor ?: return
        val fresh = toRecords(source.since(from, floor))
        val settled = toRecords(source.byIds(pendingIds)).filter { it.status != PENDING }
        if (fresh.isEmpty() && settled.isEmpty()) return
        sendBatch(settled + fresh, done = true)
        cursor = maxOf(from, fresh.maxOfOrNull { it.id } ?: 0)
        pendingIds = pendingIds - settled.map { it.id }.toSet() + fresh.pendingIds()
    }

    @Synchronized
    fun reset() {
        cursor = null
        pendingIds = emptySet()
    }

    private fun toRecords(rows: List<SmsRow>): List<SmsRecord> {
        val cache = HashMap<String, String?>()
        return rows.mapNotNull { row -> row.toRecord(cache.getOrPut(row.address) { names.lookup(row.address) }) }
    }

    private fun List<SmsRecord>.pendingIds() = filter { it.status == PENDING }.map { it.id }.toSet()

    private fun sendBatch(records: List<SmsRecord>, done: Boolean) =
        send(Codec.encode(MsgType.SMS_BATCH, SmsBatch(records, done)))

    private companion object {
        const val CHUNK = 200
        const val PENDING = "pending"
    }
}
