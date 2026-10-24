package app.volley.android.sms

import app.volley.android.protocol.Attachment
import app.volley.android.protocol.Participant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MmsSourceTest {
    private val names = ContactNames { mapOf("+15550001111" to "Ana", "+15550002222" to "Bob")[it] }
    private val own = "+15559990000"

    private fun row(box: Int = 1, mType: Int = 132) = MmsRow(id = 7, threadId = 3, date = 1_700_000_000, box, mType)

    private val text = MmsPart(id = 70, mime = "text/plain", name = null, text = "hi all", size = 6)
    private val smil = MmsPart(id = 71, mime = "application/smil", name = "smil.xml", text = "<smil/>", size = 7)
    private val photo = MmsPart(id = 72, mime = "image/jpeg", name = "IMG_1.jpg", text = null, size = 50_000)

    @Test
    fun incomingGroupMapsSenderAndParticipants() {
        val addrs = listOf(
            MmsAddr("+15550001111", FROM),
            MmsAddr(own, TO),
            MmsAddr("+15550002222", TO),
            MmsAddr("+15550003333", CC),
        )
        val r = row().toRecord(addrs, listOf(smil, text), own, names)!!
        assertEquals("mms", r.kind)
        assertFalse(r.outgoing)
        assertEquals("received", r.status)
        assertEquals("+15550001111", r.sender)
        assertEquals("+15550001111", r.address)
        assertEquals("Ana", r.contactName)
        assertEquals(
            listOf(
                Participant("+15550001111", "Ana"),
                Participant("+15550002222", "Bob"),
                Participant("+15550003333", null),
            ),
            r.participants,
        )
        assertEquals("hi all", r.body)
        assertTrue(r.attachments.isEmpty())
    }

    @Test
    fun sentGroupIsOutgoingWithAllRecipients() {
        val addrs =
            listOf(MmsAddr("insert-address-token", FROM), MmsAddr("+15550001111", TO), MmsAddr("+15550002222", TO))
        val r = row(box = 2, mType = 128).toRecord(addrs, listOf(text), own, names)!!
        assertTrue(r.outgoing)
        assertEquals("sent", r.status)
        assertNull(r.sender)
        assertEquals("+15550001111", r.address)
        assertEquals(listOf("+15550001111", "+15550002222"), r.participants.map { it.address })
    }

    @Test
    fun ownNumberExcludedFromParticipants() {
        // Same number written differently: the comparison is on the last 10 digits.
        val addrs = listOf(MmsAddr("+15550001111", FROM), MmsAddr("(555) 999-0000", TO), MmsAddr("+15550002222", TO))
        val r = row().toRecord(addrs, listOf(text), own, names)!!
        assertEquals(listOf("+15550001111", "+15550002222"), r.participants.map { it.address })
    }

    @Test
    fun fallbackOwnNumberFromInboxRecipients() {
        val sets = listOf(
            setOf("+15559990000", "+15550002222"),
            setOf("5559990000", "+15550003333"),
            setOf("+1 555 999 0000"),
        )
        assertEquals("5559990000", ownNumberFrom(subscription = null, inboxRecipientSets = sets))
        assertEquals("5551234567", ownNumberFrom(subscription = "+1 (555) 123-4567", inboxRecipientSets = sets))
        // One group message alone can't tell us which recipient is this phone.
        assertNull(ownNumberFrom(subscription = "", inboxRecipientSets = sets.take(1)))
        assertNull(ownNumberFrom(subscription = null, inboxRecipientSets = emptyList()))
    }

    @Test
    fun secondsBecomeMillis() {
        val r = row().toRecord(listOf(MmsAddr("+15550001111", FROM)), listOf(text), own, names)!!
        assertEquals(1_700_000_000_000, r.date)
    }

    @Test
    fun photoOnlyMmsHasEmptyBody() {
        val r = row().toRecord(listOf(MmsAddr("+15550001111", FROM)), listOf(smil, photo), own, names)!!
        assertEquals("", r.body)
        assertEquals(listOf(Attachment(72, "image/jpeg", "IMG_1.jpg", 50_000)), r.attachments)
    }

    @Test
    fun boxesAndTypesMapLikeSms() {
        val addrs = listOf(MmsAddr("+15550001111", TO))
        assertEquals("pending", row(box = 4, mType = 128).toRecord(addrs, listOf(text), own, names)!!.status)
        assertEquals("failed", row(box = 5, mType = 128).toRecord(addrs, listOf(text), own, names)!!.status)
        assertNull(row(box = 3, mType = 128).toRecord(addrs, listOf(text), own, names))
        // A download notification isn't a message yet.
        assertNull(row(box = 1, mType = 130).toRecord(addrs, listOf(text), own, names))
    }

    private companion object {
        const val FROM = 137
        const val TO = 151
        const val CC = 130
    }
}
