package app.volley.android.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.provider.Telephony
import android.telephony.SmsManager
import app.volley.android.graph
import app.volley.android.protocol.Codec
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.SmsReceived
import app.volley.android.protocol.SmsSend
import app.volley.android.protocol.SmsSent
import app.volley.android.protocol.SmsSync
import app.volley.android.protocol.bodyAs
import app.volley.android.session.MessageHandler
import app.volley.android.session.SessionManager

interface SmsSender {
    fun send(address: String, body: String): Result<Unit>
}

class SystemSmsSender(context: Context) : SmsSender {
    private val sms: SmsManager = context.getSystemService(SmsManager::class.java)

    override fun send(address: String, body: String): Result<Unit> = runCatching {
        val parts = sms.divideMessage(body)
        if (parts.size == 1) sms.sendTextMessage(address, null, body, null, null)
        else sms.sendMultipartTextMessage(address, null, parts, null, null)
    }
}

/** Handles `sms.send` from the Mac and replies with `sms.sent`. */
class SmsSendHandler(
    private val sender: SmsSender,
    private val session: SessionManager,
) : MessageHandler {
    override fun handle(envelope: app.volley.android.protocol.Envelope) {
        val req = envelope.bodyAs<SmsSend>() ?: return
        val result = sender.send(req.address, req.body)
        result.exceptionOrNull()?.let { Log.w("VolleySms", "Send failed", it) } ?: Log.i("VolleySms", "Sent")
        session.send(
            Codec.encode(
                MsgType.SMS_SENT,
                SmsSent(req.requestId, result.isSuccess, result.exceptionOrNull()?.message),
            ),
        )
    }
}

/** Handles `sms.sync` from the Mac. */
class SmsSyncHandler(private val syncer: SmsSyncer) : MessageHandler {
    override fun handle(envelope: app.volley.android.protocol.Envelope) {
        val req = envelope.bodyAs<SmsSync>() ?: return
        syncer.syncFrom(req.sinceId, req.sinceTime, req.pendingIds)
    }
}

/** Forwards incoming SMS to the Mac. Multi-part messages arrive as one broadcast. */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (parts.isEmpty()) return

        val session = context.graph.session
        parts.groupBy { it.originatingAddress.orEmpty() }.forEach { (address, msgs) ->
            val body = msgs.joinToString(separator = "") { it.messageBody.orEmpty() }
            val frame = Codec.encode(MsgType.SMS_RECEIVED, SmsReceived(address, body, msgs.first().timestampMillis))
            session.send(frame, bufferIfOffline = true)
        }
    }
}
