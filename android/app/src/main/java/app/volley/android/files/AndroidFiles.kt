package app.volley.android.files

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.media.ThumbnailUtils
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.File

/** Android-specific pieces of file serving: access checks, thumbnails, media scan, Wi-Fi lock. */
class AndroidFiles(private val context: Context) {
    val root: File = Environment.getExternalStorageDirectory()

    fun hasAccess(): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    /** JPEG thumbnail for images and videos, or null for anything else. */
    fun thumbnail(file: File, maxPx: Int): ByteArray? {
        val bitmap = runCatching {
            val name = file.name.lowercase()
            when {
                name.endsWith(".mp4") || name.endsWith(".mov") || name.endsWith(".mkv") || name.endsWith(".webm") ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        ThumbnailUtils.createVideoThumbnail(file, Size(maxPx, maxPx), null)
                    } else {
                        null
                    }
                else -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ThumbnailUtils.createImageThumbnail(file, Size(maxPx, maxPx), null)
                } else {
                    decodeSampled(file, maxPx)
                }
            }
        }.getOrNull() ?: return null
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            bitmap.recycle()
            out.toByteArray()
        }
    }

    /** Tells the media store about added or deleted files so Gallery and other apps see them. */
    fun scan(relative: String) {
        MediaScannerConnection.scanFile(context, arrayOf(File(root, relative).path), null, null)
    }

    private val wifiLock: WifiManager.WifiLock? by lazy {
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        context.getSystemService(WifiManager::class.java)?.createWifiLock(mode, "volley:transfer")
            ?.apply { setReferenceCounted(false) }
    }

    /** Keeps Wi-Fi at full speed while a transfer runs, even with the screen off. */
    fun setTransferActive(active: Boolean) {
        val lock = wifiLock ?: return
        if (active) {
            lock.acquire()
        } else if (lock.isHeld) {
            lock.release()
        }
    }

    private fun decodeSampled(file: File, maxPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= maxPx && bounds.outHeight / (sample * 2) >= maxPx) sample *= 2
        return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private companion object {
        const val JPEG_QUALITY = 70
    }
}
