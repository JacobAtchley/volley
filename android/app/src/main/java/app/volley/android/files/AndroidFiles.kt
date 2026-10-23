package app.volley.android.files

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.media.ThumbnailUtils
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Size
import androidx.annotation.RequiresApi
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
        return bitmap.toJpeg()
    }

    private fun Bitmap.toJpeg(): ByteArray = ByteArrayOutputStream().use { out ->
        compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
        recycle()
        out.toByteArray()
    }

    /** Folder → (file name → media id), so one MediaStore query serves a whole folder of thumbnails. */
    private val mediaIds = object : LinkedHashMap<String, Map<String, Pair<Long, Int>>>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Map<String, Pair<Long, Int>>>) =
            size > MEDIA_FOLDERS_CACHED
    }

    /** Android's cached Gallery thumbnail (fast), or null when the file isn't in the media library. */
    fun mediaThumbnail(file: File, maxPx: Int): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val folder = file.parentFile?.relativeTo(root)?.path?.let { if (it.isEmpty()) "" else "$it/" } ?: return null
        val ids = synchronized(mediaIds) { mediaIds.getOrPut(folder) { queryMediaIds(folder) } }
        val (id, type) = ids[file.name] ?: return null
        val base = if (type == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val bitmap = runCatching {
            context.contentResolver.loadThumbnail(ContentUris.withAppendedId(base, id), Size(maxPx, maxPx), null)
        }.getOrNull() ?: return null
        return bitmap.toJpeg()
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun queryMediaIds(folder: String): Map<String, Pair<Long, Int>> = runCatching {
        val cols = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
        )
        context.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            cols,
            "${MediaStore.Files.FileColumns.RELATIVE_PATH} = ? AND ${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)",
            arrayOf(
                folder,
                MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
                MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            ),
            null,
        )?.use { c ->
            buildMap { while (c.moveToNext()) put(c.getString(1), c.getLong(0) to c.getInt(2)) }
        }.orEmpty()
    }.getOrDefault(emptyMap())

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
        const val MEDIA_FOLDERS_CACHED = 8
    }
}
