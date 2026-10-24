package app.volley.android.mms

import com.google.android.mms.pdu_alt.PduHeaders
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SendConfTest {
    // Minimal M-Send.conf: message-type send-conf, transaction id "T", MMS version 1.2, response status.
    private fun conf(status: Int) = byteArrayOf(
        0x8C.toByte(), 0x81.toByte(),
        0x98.toByte(), 'T'.code.toByte(), 0,
        0x8D.toByte(), 0x92.toByte(),
        0x92.toByte(), status.toByte(),
    )

    @Test
    fun okStatusIsNoError() = assertNull(SendConf.error(conf(PduHeaders.RESPONSE_STATUS_OK)))

    @Test
    fun carrierRejectionIsAnError() {
        assertEquals(
            "Carrier rejected the MMS (status 0x%02X)".format(
                PduHeaders.RESPONSE_STATUS_ERROR_PERMANENT_CONTENT_NOT_ACCEPTED,
            ),
            SendConf.error(conf(PduHeaders.RESPONSE_STATUS_ERROR_PERMANENT_CONTENT_NOT_ACCEPTED)),
        )
    }

    @Test
    fun missingResponseIsNoError() = assertNull(SendConf.error(null))
}
