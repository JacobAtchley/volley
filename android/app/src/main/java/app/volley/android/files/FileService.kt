package app.volley.android.files

import app.volley.android.protocol.FsDeleteFailure
import app.volley.android.protocol.FsEntry
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.URLConnection

/** File operations the Mac can ask for, on paths relative to shared storage. */
interface FileService {
    fun list(path: String, showHidden: Boolean): Result<List<FsEntry>>

    fun delete(paths: List<String>): List<FsDeleteFailure>

    /** Stream and size of a file. */
    fun openRead(path: String): Result<Pair<InputStream, Long>>

    /** Creates [name] in [dir] (making missing folders), renaming Android-style on a clash; returns the final name. */
    fun createForUpload(dir: String, name: String): Result<Pair<String, OutputStream>>

    /** Deletes a partial upload. */
    fun discard(path: String)

    fun thumbnail(path: String, maxPx: Int): Result<ByteArray>
}

class DiskFileService(private val paths: StoragePaths, private val thumbnails: (File, Int) -> ByteArray?) :
    FileService {
    override fun list(path: String, showHidden: Boolean): Result<List<FsEntry>> = runCatching {
        val dir = paths.resolve(path)?.takeIf { it.isDirectory } ?: throw IOException("Not a folder: $path")
        dir.listFiles().orEmpty()
            .filter { showHidden || !it.name.startsWith(".") }
            .filter { paths.resolve(paths.relativeOf(it)) != null }
            .map { f ->
                FsEntry(
                    name = f.name,
                    isDir = f.isDirectory,
                    size = if (f.isDirectory) 0 else f.length(),
                    modified = f.lastModified(),
                    mime = if (f.isDirectory) null else URLConnection.guessContentTypeFromName(f.name),
                )
            }
            .sortedWith(compareBy<FsEntry>({ !it.isDir }, { it.name.lowercase() }))
    }

    override fun delete(paths: List<String>): List<FsDeleteFailure> = paths.mapNotNull { path ->
        val file = this.paths.resolve(path)
        when {
            file == null || this.paths.isProtected(file) -> FsDeleteFailure(path, "Not allowed")
            !file.exists() -> FsDeleteFailure(path, "Not found")
            !file.deleteRecursively() -> FsDeleteFailure(path, "Couldn't delete")
            else -> null
        }
    }

    override fun openRead(path: String): Result<Pair<InputStream, Long>> = runCatching {
        val file = paths.resolve(path)?.takeIf { it.isFile } ?: throw IOException("Not a file: $path")
        FileInputStream(file) to file.length()
    }

    override fun createForUpload(dir: String, name: String): Result<Pair<String, OutputStream>> = runCatching {
        require(name.isNotEmpty() && '/' !in name && name != "." && name != "..") { "Bad name: $name" }
        val folder = paths.resolve(dir) ?: throw IOException("Not allowed: $dir")
        if (!folder.isDirectory && !folder.mkdirs()) throw IOException("Couldn't create $dir")
        val finalName = StoragePaths.uniqueName(folder.list().orEmpty().toSet(), name)
        val target = paths.resolve(paths.relativeOf(File(folder, finalName))) ?: throw IOException("Not allowed")
        finalName to FileOutputStream(target)
    }

    override fun discard(path: String) {
        paths.resolve(path)?.takeIf { it.isFile }?.delete()
    }

    override fun thumbnail(path: String, maxPx: Int): Result<ByteArray> = runCatching {
        val file = paths.resolve(path)?.takeIf { it.isFile } ?: throw IOException("Not a file: $path")
        thumbnails(file, maxPx) ?: throw IOException("No thumbnail")
    }
}
