package app.volley.android.mms

import android.content.ContentResolver
import android.content.Context
import android.content.ContextWrapper
import com.google.android.mms.pdu_alt.CharacterSets
import com.google.android.mms.pdu_alt.EncodedStringValue
import com.google.android.mms.pdu_alt.PduBody
import com.google.android.mms.pdu_alt.PduComposer
import com.google.android.mms.pdu_alt.PduHeaders
import com.google.android.mms.pdu_alt.PduPart
import com.google.android.mms.pdu_alt.SendReq

/** Builds an M-Send.req PDU. Android has no public API for this, so the klinker PDU classes do the encoding. */
object MmsComposer {
    /** Every part carries its bytes inline, so the composer never needs a real content resolver. */
    private object NoResolver : ContextWrapper(null) {
        override fun getContentResolver(): ContentResolver? = null
    }

    fun compose(
        to: List<String>,
        text: String?,
        images: List<Pair<String, ByteArray>>,
        context: Context = NoResolver,
    ): ByteArray {
        val req = SendReq()
        to.forEach { req.addTo(EncodedStringValue(it)) }
        req.date = System.currentTimeMillis() / 1000
        req.messageClass = PduHeaders.MESSAGE_CLASS_PERSONAL_STR.toByteArray()
        req.expiry = WEEK_SECONDS
        req.priority = PduHeaders.PRIORITY_NORMAL
        req.deliveryReport = PduHeaders.VALUE_NO
        req.readReport = PduHeaders.VALUE_NO
        val body = PduBody()
        val names = images.mapIndexed { i, (name, _) -> name.ifEmpty { "image_$i.jpg" } }
        val hasText = !text.isNullOrEmpty()
        // A SMIL layout first: multipart/related messages start from it, and carriers and Messages apps reject
        // photo MMS without one ("invalid message"). The composer makes it the start part.
        body.addPart(part("application/smil", "smil.smil", smil(names, if (hasText) TEXT_NAME else null).toByteArray()))
        if (hasText) {
            body.addPart(
                part("text/plain", TEXT_NAME, text!!.toByteArray(Charsets.UTF_8)).apply {
                    charset =
                        CharacterSets.UTF_8
                },
            )
        }
        images.forEachIndexed { i, (_, bytes) -> body.addPart(part("image/jpeg", names[i], bytes)) }
        req.body = body
        req.messageSize = body.let { b -> (0 until b.partsNum).sumOf { b.getPart(it).data.size.toLong() } }
        return PduComposer(context, req).make() ?: error("Couldn't build the MMS")
    }

    private fun part(type: String, name: String, bytes: ByteArray) = PduPart().apply {
        contentType = type.toByteArray()
        contentLocation = name.toByteArray()
        contentId = "<${name.substringBeforeLast('.')}>".toByteArray()
        data = bytes
    }

    /** One slide per photo; the caption goes with the first (or alone when there are no photos). */
    internal fun smil(images: List<String>, text: String?): String {
        val slides = if (images.isEmpty()) {
            listOf("""<par dur="5000ms"><text src="$text" region="Text"/></par>""")
        } else {
            images.mapIndexed { i, name ->
                val caption = if (i == 0 && text != null) """<text src="$text" region="Text"/>""" else ""
                """<par dur="5000ms"><img src="$name" region="Image"/>$caption</par>"""
            }
        }
        return "<smil><head><layout><root-layout/>" +
            """<region id="Image" fit="meet" top="0" left="0" height="80%" width="100%"/>""" +
            """<region id="Text" top="80%" left="0" height="20%" width="100%"/>""" +
            "</layout></head><body>" + slides.joinToString("") + "</body></smil>"
    }

    private const val TEXT_NAME = "text_0.txt"
    private const val WEEK_SECONDS = 7 * 24 * 3600L
}
