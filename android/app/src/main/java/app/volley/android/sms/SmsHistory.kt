package app.volley.android.sms

import android.content.ContentResolver
import android.net.Uri
import android.provider.ContactsContract.PhoneLookup
import android.provider.Telephony.Sms
import app.volley.android.protocol.Codec
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.SmsBatch
import app.volley.android.protocol.SmsRecord
import java.util.Optional
import java.util.concurrent.ConcurrentHashMap

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
class SmsSyncer(private val source: SmsSource, private val names: ContactNames, private val send: (String) -> Unit) {
    private var cursor: Long? = null
    private var floor = 0L
    private var pendingIds = emptySet<Long>()

    /** [macPendingIds] are rows the Mac holds as pending; they're resent so it learns how they settled. */
    @Synchronized
    fun syncFrom(sinceId: Long, sinceTime: Long, macPendingIds: Collection<Long> = emptyList()) {
        val fresh = toRecords(source.since(sinceId, sinceTime))
        val old = toRecords(source.byIds(macPendingIds.filter { it <= sinceId }))
        val records = old + fresh
        val chunks = records.chunked(CHUNK).ifEmpty { listOf(emptyList()) }
        chunks.forEachIndexed { i, chunk -> sendBatch(chunk, done = i == chunks.lastIndex) }
        cursor = maxOf(sinceId, fresh.maxOfOrNull { it.id } ?: 0)
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

/** [SmsSource] backed by the system SMS provider. Returns nothing without READ_SMS. */
class ContentResolverSmsSource(private val resolver: ContentResolver) : SmsSource {
    override fun since(sinceId: Long, sinceTime: Long) =
        query("${Sms._ID} > ? AND ${Sms.DATE} >= ? AND $TYPES", arrayOf(sinceId.toString(), sinceTime.toString()))

    override fun byIds(ids: Collection<Long>): List<SmsRow> = if (ids.isEmpty()) {
        emptyList()
    } else {
        query("${Sms._ID} IN (${ids.joinToString { "?" }}) AND $TYPES", ids.map { it.toString() }.toTypedArray())
    }

    private fun query(selection: String, args: Array<String>): List<SmsRow> = try {
        resolver.query(Sms.CONTENT_URI, COLUMNS, selection, args, "${Sms._ID} ASC")?.use { c ->
            buildList {
                while (c.moveToNext()) {
                    add(
                        SmsRow(
                            c.getLong(0),
                            c.getLong(1),
                            c.getString(2).orEmpty(),
                            c.getString(3).orEmpty(),
                            c.getLong(4),
                            c.getInt(5),
                        ),
                    )
                }
            }
        }.orEmpty()
    } catch (e: SecurityException) {
        emptyList()
    }

    private companion object {
        val COLUMNS = arrayOf(Sms._ID, Sms.THREAD_ID, Sms.ADDRESS, Sms.BODY, Sms.DATE, Sms.TYPE)
        const val TYPES = "${Sms.TYPE} IN (1, 2, 4, 5, 6)"
    }
}

/** Contact names via PhoneLookup, cached for the app's lifetime. Returns null without READ_CONTACTS. */
class PhoneLookupContactNames(private val resolver: ContentResolver) : ContactNames {
    private val cache = ConcurrentHashMap<String, Optional<String>>()

    override fun lookup(address: String): String? {
        if (address.isBlank()) return null
        cache[address]?.let { return it.orElse(null) }
        val name = try {
            val uri = Uri.withAppendedPath(PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address))
            resolver.query(uri, arrayOf(PhoneLookup.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (e: SecurityException) {
            return null // don't cache: permission may be granted later
        }
        cache[address] = Optional.ofNullable(name)
        return name
    }
}
