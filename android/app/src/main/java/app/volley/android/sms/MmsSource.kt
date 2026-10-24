package app.volley.android.sms

import android.content.ContentResolver
import android.net.Uri
import android.provider.Telephony.Mms
import app.volley.android.protocol.Attachment
import app.volley.android.protocol.Participant
import app.volley.android.protocol.SmsRecord

/** One row of the MMS provider. [date] is in seconds; [box] is `msg_box`, [mType] is `m_type`. */
data class MmsRow(val id: Long, val threadId: Long, val date: Long, val box: Int, val mType: Int)

/** [type] is 137 from, 151 to, 130 cc. */
data class MmsAddr(val address: String, val type: Int)

data class MmsPart(
    val id: Long,
    val mime: String,
    val name: String?,
    val text: String?,
    val size: Long,
    val width: Int? = null,
    val height: Int? = null,
)

/**
 * Maps an MMS to the wire record; null for rows we don't sync (drafts, download notifications).
 * [ownNumber] (any format) is left out of the participants so replies never go back to this phone.
 */
fun MmsRow.toRecord(addrs: List<MmsAddr>, parts: List<MmsPart>, ownNumber: String?, names: ContactNames): SmsRecord? {
    if (mType != M_SEND_REQ && mType != M_RETRIEVE_CONF) return null
    val (status, outgoing) = when (box) {
        1 -> "received" to false
        2 -> "sent" to true
        4 -> "pending" to true
        5 -> "failed" to true
        else -> return null
    }
    val own = ownNumber?.let(::normalize)?.takeIf { it.isNotEmpty() }
    val sender = if (outgoing) null else addrs.firstOrNull { it.type == ADDR_FROM }?.address
    val seen = HashSet<String>()
    val participants = addrs
        .filter { it.type == ADDR_FROM && !outgoing || it.type == ADDR_TO || it.type == ADDR_CC }
        .filter { it.address.isNotBlank() && it.address != ADDRESS_TOKEN }
        .filter { normalize(it.address).let { n -> n != own && seen.add(n) } }
        .map { Participant(it.address, names.lookup(it.address)) }
    val address = sender ?: participants.firstOrNull()?.address.orEmpty()
    val body = parts.filter { it.mime == "text/plain" }.mapNotNull { it.text }.joinToString("\n")
    val attachments = parts
        .filter { it.mime != "text/plain" && it.mime != "application/smil" }
        .map { Attachment(it.id, it.mime, it.name, it.size, it.width, it.height) }
    return SmsRecord(
        id = id,
        threadId = threadId,
        address = address,
        contactName = participants.firstOrNull { it.address == address }?.contactName ?: names.lookup(address),
        body = body,
        date = date * 1000,
        outgoing = outgoing,
        status = status,
        kind = "mms",
        participants = participants,
        sender = sender,
        attachments = attachments,
    )
}

/** "Ana", "Ana, Bob" or "Ana, Bob +2": names where known, numbers otherwise. */
fun conversationTitle(participants: List<Participant>): String {
    val labels = participants.map { it.contactName ?: it.address }
    return when {
        labels.size <= 2 -> labels.joinToString(", ")
        else -> "${labels.take(2).joinToString(", ")} +${labels.size - 2}"
    }
}

/** Reads MMS rows ordered by ascending `_id`, including download notifications (m_type 130). */
interface MmsSourceApi {
    fun since(sinceId: Long, sinceTimeSec: Long): List<MmsRow>
    fun byIds(ids: Collection<Long>): List<MmsRow>
    fun addrs(id: Long): List<MmsAddr>
    fun parts(id: Long): List<MmsPart>
}

/** [MmsSourceApi] backed by the system MMS provider. Returns nothing without READ_SMS. */
class ContentResolverMmsSource(private val resolver: ContentResolver) : MmsSourceApi {
    override fun since(sinceId: Long, sinceTimeSec: Long) =
        rows("${Mms._ID} > ? AND ${Mms.DATE} >= ? AND $FILTER", arrayOf(sinceId.toString(), sinceTimeSec.toString()))

    override fun byIds(ids: Collection<Long>): List<MmsRow> = if (ids.isEmpty()) {
        emptyList()
    } else {
        rows("${Mms._ID} IN (${ids.joinToString { "?" }}) AND $FILTER", ids.map { it.toString() }.toTypedArray())
    }

    /** Recipient sets of recent incoming MMS, for finding this phone's own number. */
    fun recentInboxRecipients(limit: Int = 30): List<Set<String>> = rows(
        "${Mms.MESSAGE_BOX} = 1 AND ${Mms.MESSAGE_TYPE} = $M_RETRIEVE_CONF",
        emptyArray(),
        "${Mms._ID} DESC LIMIT $limit",
    )
        .map { row -> addrs(row.id).filter { it.type == ADDR_TO || it.type == ADDR_CC }.map { it.address }.toSet() }

    override fun addrs(id: Long): List<MmsAddr> = safely {
        resolver.query(Uri.parse("content://mms/$id/addr"), arrayOf("address", "type"), null, null, null)?.use { c ->
            buildList { while (c.moveToNext()) add(MmsAddr(c.getString(0).orEmpty(), c.getInt(1))) }
        }
    }

    override fun parts(id: Long): List<MmsPart> = safely {
        val columns =
            arrayOf(Mms.Part._ID, Mms.Part.CONTENT_TYPE, Mms.Part.NAME, Mms.Part.CONTENT_LOCATION, Mms.Part.TEXT)
        resolver.query(
            PARTS,
            columns,
            "${Mms.Part.MSG_ID} = ?",
            arrayOf(id.toString()),
            "${Mms.Part._ID} ASC",
        )?.use { c ->
            buildList {
                while (c.moveToNext()) {
                    val partId = c.getLong(0)
                    val mime = c.getString(1).orEmpty().lowercase()
                    val text = c.getString(4)
                    val size = if (mime.startsWith("text/") || mime == "application/smil") {
                        text?.toByteArray()?.size?.toLong() ?: 0
                    } else {
                        partSize(partId)
                    }
                    add(MmsPart(partId, mime, c.getString(2) ?: c.getString(3), text, size))
                }
            }
        }
    }

    private fun partSize(partId: Long): Long = try {
        resolver.openFileDescriptor(Uri.parse("content://mms/part/$partId"), "r")?.use { it.statSize } ?: 0
    } catch (e: Exception) {
        0
    }

    private fun rows(selection: String, args: Array<String>, order: String = "${Mms._ID} ASC"): List<MmsRow> = safely {
        resolver.query(Mms.CONTENT_URI, COLUMNS, selection, args, order)?.use { c ->
            buildList {
                while (c.moveToNext()) add(MmsRow(c.getLong(0), c.getLong(1), c.getLong(2), c.getInt(3), c.getInt(4)))
            }
        }
    }

    private fun <T> safely(block: () -> List<T>?): List<T> = try {
        block().orEmpty()
    } catch (e: SecurityException) {
        emptyList()
    }

    private companion object {
        val PARTS: Uri = Uri.parse("content://mms/part")
        val COLUMNS = arrayOf(Mms._ID, Mms.THREAD_ID, Mms.DATE, Mms.MESSAGE_BOX, Mms.MESSAGE_TYPE)
        const val FILTER = "${Mms.MESSAGE_BOX} IN (1, 2, 4, 5) AND ${Mms.MESSAGE_TYPE} IN (128, 130, 132)"
    }
}

const val M_SEND_REQ = 128
const val M_NOTIFICATION_IND = 130
const val M_RETRIEVE_CONF = 132
private const val ADDR_FROM = 137
private const val ADDR_TO = 151
private const val ADDR_CC = 130
private const val ADDRESS_TOKEN = "insert-address-token"
