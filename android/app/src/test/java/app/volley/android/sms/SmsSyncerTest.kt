package app.volley.android.sms

import app.volley.android.protocol.Codec
import app.volley.android.protocol.MmsReceived
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.SmsBatch
import app.volley.android.protocol.bodyAs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsSyncerTest {
    private class FakeSource(var rows: List<SmsRow> = emptyList()) : SmsSource {
        override fun since(sinceId: Long, sinceTime: Long) =
            rows.filter { it.id > sinceId && it.date >= sinceTime }.sortedBy { it.id }
        override fun byIds(ids: Collection<Long>) = rows.filter { it.id in ids }.sortedBy { it.id }
    }

    private class FakeMms(var rows: List<MmsRow> = emptyList()) : MmsSourceApi {
        override fun since(sinceId: Long, sinceTimeSec: Long) =
            rows.filter { it.id > sinceId && it.date >= sinceTimeSec }.sortedBy { it.id }
        override fun byIds(ids: Collection<Long>) = rows.filter { it.id in ids }.sortedBy { it.id }
        override fun addrs(id: Long) = listOf(MmsAddr("+1555", 137), MmsAddr("+1777", 151), MmsAddr("+1999", 151))
        override fun parts(id: Long) = listOf(MmsPart(id * 10, "text/plain", null, "g$id", 2))
    }

    private val source = FakeSource()
    private val mms = FakeMms()
    private val lookups = mutableListOf<String>()
    private val names = ContactNames {
        lookups += it
        if (it == "+1555") "Ana" else null
    }
    private val frames = mutableListOf<String>()
    private val syncer = SmsSyncer(source, names, mms = mms, ownNumber = { "+1777" }) { frames += it }
    private val envelopes get() = frames.map { Codec.decode(it)!! }
    private val batches get() = envelopes.filter { it.type == MsgType.SMS_BATCH }.map { it.bodyAs<SmsBatch>()!! }
    private val received get() = envelopes.filter { it.type == MsgType.MMS_RECEIVED }.map { it.bodyAs<MmsReceived>()!! }

    private fun mmsRow(id: Long, box: Int = 1, mType: Int = 132, dateSec: Long = 2) =
        MmsRow(id, threadId = 9, date = dateSec, box = box, mType = mType)

    private fun row(id: Long, type: Int = 1, date: Long = 2_000, address: String = "+1555") =
        SmsRow(id, threadId = 1, address = address, body = "m$id", date = date, type = type)

    @Test
    fun toRecord_mapsTypes() {
        val expected = mapOf(
            1 to ("received" to false),
            2 to ("sent" to true),
            4 to ("pending" to true),
            5 to ("failed" to true),
            6 to ("pending" to true),
        )
        expected.forEach { (type, want) ->
            val r = row(1, type).toRecord("Ana")!!
            assertEquals(want, r.status to r.outgoing)
            assertEquals("Ana", r.contactName)
        }
        assertNull(row(1, 3).toRecord(null))
    }

    @Test
    fun syncFrom_emptySource_sendsSingleDoneBatch() {
        syncer.syncFrom(0, 0)
        assertEquals(listOf(SmsBatch(emptyList(), done = true)), batches)
    }

    @Test
    fun syncFrom_chunksAt200() {
        source.rows = (1L..450L).map { row(it) }
        syncer.syncFrom(0, 0)
        assertEquals(listOf(200, 200, 50), batches.map { it.messages.size })
        assertEquals(listOf(false, false, true), batches.map { it.done })
    }

    @Test
    fun syncFrom_appliesBothCursorAndTime() {
        source.rows = listOf(row(5, date = 900), row(6, date = 1_100), row(3, date = 1_200))
        syncer.syncFrom(4, 1_000)
        assertEquals(listOf(6L), batches.single().messages.map { it.id })
    }

    @Test
    fun onChanged_beforeSync_sendsNothing() {
        source.rows = listOf(row(1))
        syncer.onChanged()
        assertTrue(frames.isEmpty())
    }

    @Test
    fun onChanged_sendsOnlyNewRows() {
        source.rows = listOf(row(1))
        syncer.syncFrom(0, 0)
        frames.clear()
        syncer.onChanged()
        assertTrue(frames.isEmpty())
        source.rows = listOf(row(1), row(2))
        syncer.onChanged()
        assertEquals(listOf(SmsBatch(listOf(row(2).toRecord("Ana")!!), done = true)), batches)
    }

    @Test
    fun onChanged_resendsPendingWhenStatusChanges() {
        source.rows = listOf(row(7, type = 4))
        syncer.syncFrom(0, 0)
        frames.clear()
        source.rows = listOf(row(7, type = 2))
        syncer.onChanged()
        assertEquals(listOf("sent"), batches.single().messages.map { it.status })
        frames.clear()
        syncer.onChanged()
        assertTrue(frames.isEmpty())
    }

    @Test
    fun contactNameIsAttached_lookupOncePerAddress() {
        source.rows = listOf(row(1), row(2), row(3, address = "+1999"))
        syncer.syncFrom(0, 0)
        assertEquals(listOf("Ana", "Ana", null), batches.single().messages.map { it.contactName })
        assertEquals(listOf("+1555", "+1999"), lookups)
    }

    @Test
    fun reset_stopsOnChanged() {
        syncer.syncFrom(0, 0)
        syncer.reset()
        frames.clear()
        source.rows = listOf(row(1))
        syncer.onChanged()
        assertTrue(frames.isEmpty())
    }

    @Test
    fun syncFrom_resendsRowsTheMacStillHasPending() {
        source.rows = listOf(row(5, type = 2), row(9))
        syncer.syncFrom(9, 0, macPendingIds = listOf(5))
        assertEquals(listOf(5L to "sent"), batches.single().messages.map { it.id to it.status })
    }

    @Test
    fun syncFrom_keepsWatchingMacPendingRows() {
        source.rows = listOf(row(5, type = 4))
        syncer.syncFrom(9, 0, macPendingIds = listOf(5))
        frames.clear()
        source.rows = listOf(row(5, type = 5))
        syncer.onChanged()
        assertEquals(listOf(5L to "failed"), batches.single().messages.map { it.id to it.status })
    }

    @Test
    fun syncFromMergesSmsAndMmsByCursor() {
        source.rows = listOf(row(1), row(2))
        mms.rows = listOf(mmsRow(1), mmsRow(5), mmsRow(6, dateSec = 0))
        syncer.syncFrom(1, 1_000, sinceMmsId = 1)
        assertEquals(listOf("sms" to 2L, "mms" to 5L), batches.single().messages.map { it.kind to it.id })
        frames.clear()
        source.rows += row(3)
        mms.rows += mmsRow(8)
        syncer.onChanged()
        assertEquals(listOf("sms" to 3L, "mms" to 8L), batches.single().messages.map { it.kind to it.id })
    }

    @Test
    fun mmsPendingResentWhenSettled() {
        mms.rows = listOf(mmsRow(4, box = 4, mType = 128), mmsRow(2, box = 4, mType = 128))
        syncer.syncFrom(0, 0, sinceMmsId = 3, macPendingMmsIds = listOf(2))
        frames.clear()
        mms.rows = listOf(mmsRow(4, box = 2, mType = 128), mmsRow(2, box = 5, mType = 128))
        syncer.onChanged()
        assertEquals(
            listOf(2L to "failed", 4L to "sent"),
            batches.single().messages.map {
                it.id to it.status
            }.sortedBy { it.first },
        )
        frames.clear()
        syncer.onChanged()
        assertTrue(frames.isEmpty())
    }

    @Test
    fun downloadingMmsIsSentOnceRetrieved() {
        mms.rows = listOf(mmsRow(3, mType = 130))
        syncer.syncFrom(0, 0)
        assertTrue(batches.single().messages.isEmpty())
        frames.clear()
        mms.rows = listOf(mmsRow(3), mmsRow(4, mType = 130))
        syncer.onChanged()
        assertEquals(listOf(3L), batches.single().messages.map { it.id })
        assertEquals(listOf("g3"), received.map { it.text })
    }

    @Test
    fun newIncomingMmsRaisesReceivedButSyncDoesNot() {
        mms.rows = listOf(mmsRow(1))
        syncer.syncFrom(0, 0)
        assertTrue(received.isEmpty())
        mms.rows += listOf(mmsRow(2), mmsRow(3, box = 2, mType = 128))
        syncer.onChanged()
        assertEquals(
            listOf(
                MmsReceived(
                    threadId = 9,
                    sender = "+1555",
                    senderName = "Ana",
                    title = "Ana, +1999",
                    text = "g2",
                    hasPhoto = false,
                ),
            ),
            received,
        )
    }

    @Test
    fun olderMacWithoutMmsCursorGetsNoMms() {
        source.rows = listOf(row(1))
        mms.rows = listOf(mmsRow(1))
        syncer.syncFrom(0, 0, sinceMmsId = null)
        assertEquals(listOf("sms"), batches.single().messages.map { it.kind })
        frames.clear()
        mms.rows += mmsRow(2)
        syncer.onChanged()
        assertTrue(frames.isEmpty())
    }
}
