package app.volley.android.mms

import com.google.android.mms.pdu_alt.PduHeaders
import com.google.android.mms.pdu_alt.PduParser
import com.google.android.mms.pdu_alt.SendConf as SendConfPdu

/**
 * The carrier's reply to a send (M-Send.conf). The system reports RESULT_OK once the carrier answered at all,
 * even if the answer is a rejection, so the response status decides whether the MMS really went out.
 */
object SendConf {
    /** null when the carrier accepted the message (or sent no reply to inspect). */
    fun error(response: ByteArray?): String? {
        if (response == null || response.isEmpty()) return null
        val conf = runCatching { PduParser(response, true).parse() as? SendConfPdu }.getOrNull() ?: return null
        val status = conf.responseStatus
        return if (status == PduHeaders.RESPONSE_STATUS_OK || status == 0) {
            null
        } else {
            "Carrier rejected the MMS (status 0x%02X)".format(status)
        }
    }
}
