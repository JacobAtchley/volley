package app.volley.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class ProtocolTest {
    private val record = SmsRecord(
        id = 7,
        threadId = 3,
        address = "+15551234567",
        contactName = "Ana",
        body = "hi",
        date = 1_000,
        outgoing = false,
        status = "received",
    )

    @Test
    fun smsBatch_roundTrips() {
        val frame = Codec.encode(MsgType.SMS_BATCH, SmsBatch(listOf(record), done = true))
        val env = Codec.decode(frame)!!
        assertEquals("sms.batch", env.type)
        assertEquals(SmsBatch(listOf(record), done = true), env.bodyAs<SmsBatch>())
    }

    @Test
    fun deviceStatus_omitsNullLevels() {
        val frame = Codec.encode(MsgType.DEVICE_STATUS, DeviceStatus(80, charging = true, wifiConnected = false))
        val body = Codec.decode(frame)!!.body
        assertFalse("cellLevel" in body)
        assertEquals("device.status", Codec.decode(frame)!!.type)
    }

    @Test
    fun notificationBatch_roundTrips() {
        val n = NotificationPosted("k1", "com.slack", "Slack", "Ana", "deploy is green", 1_000)
        val batch = NotificationBatch(listOf(n), activeKeys = listOf("k1", "k2"), done = true)
        val env = Codec.decode(Codec.encode(MsgType.NOTIFICATION_BATCH, batch))!!
        assertEquals("notification.batch", env.type)
        assertEquals(batch, env.bodyAs<NotificationBatch>())
    }
}
