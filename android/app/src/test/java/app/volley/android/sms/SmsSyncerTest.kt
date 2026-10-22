package app.volley.android.sms

import app.volley.android.protocol.Codec
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

    private val source = FakeSource()
    private val lookups = mutableListOf<String>()
    private val names = ContactNames { lookups += it; if (it == "+1555") "Ana" else null }
    private val frames = mutableListOf<String>()
    private val syncer = SmsSyncer(source, names) { frames += it }
    private val batches get() = frames.map { Codec.decode(it)!!.bodyAs<SmsBatch>()!! }

    private fun row(id: Long, type: Int = 1, date: Long = 2_000, address: String = "+1555") =
        SmsRow(id, threadId = 1, address = address, body = "m$id", date = date, type = type)

    @Test
    fun toRecord_mapsTypes() {
        val expected = mapOf(1 to ("received" to false), 2 to ("sent" to true), 4 to ("pending" to true),
            5 to ("failed" to true), 6 to ("pending" to true))
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
}
