package app.volley.android.mms

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.Telephony.Mms
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException

/** [MmsParts] backed by `content://mms/part`. */
class AndroidMmsParts(private val resolver: ContentResolver) : MmsParts {
    override fun open(partId: Long): Result<PartStream> = runCatching {
        val uri = uri(partId)
        val size = resolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0
        val input = resolver.openInputStream(uri) ?: throw FileNotFoundException("No such part")
        PartStream(input, size, name(partId))
    }

    override fun thumbnail(partId: Long, maxPx: Int): Result<ByteArray> = runCatching {
        val uri = uri(partId)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) error("Not an image")
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPx) sample *= 2
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: error("Not an image")
        val scale = maxPx.toFloat() / maxOf(decoded.width, decoded.height)
        val bitmap = if (scale < 1) {
            Bitmap.createScaledBitmap(decoded, (decoded.width * scale).toInt(), (decoded.height * scale).toInt(), true)
        } else {
            decoded
        }
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            out.toByteArray()
        }
    }

    private fun name(partId: Long): String? = runCatching {
        resolver.query(
            Uri.parse("content://mms/part"),
            arrayOf(Mms.Part.NAME, Mms.Part.CONTENT_LOCATION, Mms.Part.FILENAME),
            "${Mms.Part._ID} = ?",
            arrayOf(partId.toString()),
            null,
        )?.use { c -> if (c.moveToFirst()) c.getString(0) ?: c.getString(1) ?: c.getString(2) else null }
    }.getOrNull()

    private fun uri(partId: Long) = Uri.parse("content://mms/part/$partId")

    private companion object {
        const val JPEG_QUALITY = 75
    }
}
