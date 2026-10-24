package app.volley.android.mms

import com.google.android.mms.pdu_alt.PduParser
import com.google.android.mms.pdu_alt.SendReq
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MmsComposerTest {
    @Test
    fun composeIncludesAllRecipientsAndParts() {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3)
        val pdu = MmsComposer.compose(
            listOf("+15551112222", "+15553334444"),
            "hello group",
            listOf("photo.jpg" to jpeg),
        )
        val req = PduParser(pdu, true).parse() as SendReq
        assertEquals(listOf("+15551112222", "+15553334444"), req.to.map { it.string })
        val parts = (0 until req.body.partsNum).map { req.body.getPart(it) }
        val types = parts.map { String(it.contentType) }
        assertTrue(types.toString(), "text/plain" in types && "image/jpeg" in types)
        assertEquals("hello group", String(parts.first { String(it.contentType) == "text/plain" }.data, Charsets.UTF_8))
        assertEquals(jpeg.toList(), parts.first { String(it.contentType) == "image/jpeg" }.data.toList())
    }

    @Test
    fun composeWithoutTextHasOnlyImages() {
        val pdu = MmsComposer.compose(listOf("+15551112222"), null, listOf("a.jpg" to byteArrayOf(1)))
        val req = PduParser(pdu, true).parse() as SendReq
        assertEquals(
            listOf("application/smil", "image/jpeg"),
            (0 until req.body.partsNum).map {
                String(req.body.getPart(it).contentType)
            },
        )
    }

    @Test
    fun photoMessagesLeadWithASmilLayoutReferencingEveryPart() {
        val pdu = MmsComposer.compose(
            listOf("+15551112222"),
            "caption",
            listOf(
                "image_0.jpg" to byteArrayOf(1),
                "image_1.jpg" to byteArrayOf(2),
            ),
        )
        val req = PduParser(pdu, true).parse() as SendReq
        val first = req.body.getPart(0)
        assertEquals("application/smil", String(first.contentType))
        val smil = String(first.data)
        assertTrue(smil, "image_0.jpg" in smil && "image_1.jpg" in smil && "text_0.txt" in smil)
        assertEquals(4, req.body.partsNum)
    }
}
