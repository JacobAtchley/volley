package app.volley.android.mms

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Sends an MMS (text and/or photos) to one or more recipients. Photos are shrunk to the carrier's MMS limit,
 * the PDU is written to a private file and handed to the system MMS service, and the outcome arrives through
 * [MmsSentReceiver]. Works without Volley being the default SMS app; Android records the message as sent.
 */
class MmsSender(private val context: Context) : MmsSending {
    override fun send(
        requestId: String,
        to: List<String>,
        text: String?,
        images: List<File>,
        onResult: (Boolean, String?) -> Unit,
    ) {
        val outcome = runCatching {
            val sms = context.getSystemService(SmsManager::class.java)
            val config = sms.carrierConfigValues
            val maxSize = config.getInt(SmsManager.MMS_CONFIG_MAX_MESSAGE_SIZE, FALLBACK_MAX_BYTES)
            val maxW = config.getInt(SmsManager.MMS_CONFIG_MAX_IMAGE_WIDTH, FALLBACK_MAX_SIDE)
            val maxH = config.getInt(SmsManager.MMS_CONFIG_MAX_IMAGE_HEIGHT, FALLBACK_MAX_SIDE)
            val textBytes = text?.toByteArray()?.size ?: 0
            val budget = (maxSize * HEADROOM).toInt() - textBytes - PDU_OVERHEAD
            val jpegs = ImageShrinker(budget, maxW, maxH).shrink(images.map(::source)).getOrThrow()
            val pdu = MmsComposer.compose(to, text, jpegs.mapIndexed { i, b -> "image_$i.jpg" to b }, context)
            Log.i(
                TAG,
                "mms to=${to.size} images=${jpegs.map {
                    it.size
                }} pdu=${pdu.size}B limit=$maxSize ${maxW}x$maxH",
            )

            val dir = File(context.cacheDir, "mms").apply { mkdirs() }
            val file = File(dir, "send-$requestId.pdu").apply { writeBytes(pdu) }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.mmsfiles", file)
            context.grantUriPermission(PHONE_PACKAGE, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            pending[requestId] = { ok, error ->
                file.delete()
                images.forEach { it.delete() }
                onResult(ok, error)
            }
            val sent = PendingIntent.getBroadcast(
                context,
                requestId.hashCode(),
                Intent(context, MmsSentReceiver::class.java).putExtra(EXTRA_REQUEST, requestId),
                // The MMS service adds result extras, so the intent must be mutable.
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            sms.sendMultimediaMessage(context, uri, null, null, sent)
        }
        outcome.exceptionOrNull()?.let {
            pending.remove(requestId)
            images.forEach(File::delete)
            onResult(false, it.message ?: "Couldn't send")
        }
    }

    private fun source(file: File): ImageShrinker.Source {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        return ImageShrinker.Source(bounds.outWidth, bounds.outHeight) { w, h, quality ->
            val bitmap = decode(file, w, h)
            ByteArrayOutputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
                bitmap.recycle()
                out.toByteArray()
            }
        }
    }

    /** Decodes at (about) the target size, applying EXIF rotation where the platform can. */
    private fun decode(file: File, w: Int, h: Int): Bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            val long = maxOf(w, h).toFloat() / maxOf(info.size.width, info.size.height)
            decoder.setTargetSize(
                (info.size.width * long).toInt().coerceAtLeast(1),
                (info.size.height * long).toInt().coerceAtLeast(1),
            )
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    } else {
        val full = BitmapFactory.decodeFile(file.path) ?: error("Not an image")
        Bitmap.createScaledBitmap(full, w, h, true).also { if (it !== full) full.recycle() }
    }

    companion object {
        const val EXTRA_REQUEST = "requestId"
        private const val TAG = "VolleyMms"
        private const val PHONE_PACKAGE = "com.android.phone"
        private const val FALLBACK_MAX_BYTES = 300_000
        private const val FALLBACK_MAX_SIDE = 1600
        private const val HEADROOM = 0.95
        private const val PDU_OVERHEAD = 4_096
        private val pending = ConcurrentHashMap<String, (Boolean, String?) -> Unit>()

        internal fun completed(requestId: String, ok: Boolean, error: String?) {
            pending.remove(requestId)?.invoke(ok, error)
        }
    }
}

/** Receives the MMS service's result for a send. */
class MmsSentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra(MmsSender.EXTRA_REQUEST) ?: return
        val error = if (resultCode != Activity.RESULT_OK) {
            "Couldn't send the MMS (code $resultCode)"
        } else {
            SendConf.error(intent.getByteArrayExtra(SmsManager.EXTRA_MMS_DATA))
        }
        Log.i("VolleyMms", "send result code=$resultCode error=$error")
        MmsSender.completed(requestId, error == null, error)
    }
}
