package app.volley.android.files

import java.io.File

/**
 * Maps the Mac's relative paths onto shared storage and refuses anything outside it: `..`, absolute paths,
 * symlinks that lead out, and other apps' private `Android/data` / `Android/obb`.
 */
class StoragePaths(root: File) {
    private val root: File = root.canonicalFile

    fun resolve(relative: String): File? {
        if (relative.startsWith("/") || relative.startsWith("\\")) return null
        val file = (if (relative.isEmpty()) root else File(root, relative)).canonicalFile
        val inside = file == root || file.path.startsWith(root.path + File.separator)
        if (!inside || isHiddenSystemDir(relativeOf(file))) return null
        return file
    }

    fun relativeOf(file: File): String = file.canonicalFile.path.removePrefix(root.path).trimStart(File.separatorChar)
        .replace(File.separatorChar, '/')

    // Shared storage is case-insensitive, so compare that way: "android/DATA" is the same folder.
    fun isHiddenSystemDir(relative: String): Boolean =
        HIDDEN.any { relative.equals(it, ignoreCase = true) || relative.startsWith("$it/", ignoreCase = true) }

    /** The storage root and `Android/` itself must never be deleted. */
    fun isProtected(file: File): Boolean =
        file.canonicalFile == root || relativeOf(file).equals("Android", ignoreCase = true)

    companion object {
        private val HIDDEN = listOf("Android/data", "Android/obb")

        /** Android-style free name: `photo.jpg` → `photo (1).jpg`, `README` → `README (1)`. */
        fun uniqueName(existing: Set<String>, name: String): String {
            val taken = existing.mapTo(HashSet()) { it.lowercase() }
            if (name.lowercase() !in taken) return name
            val dot = name.lastIndexOf('.')
            val (base, ext) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
            return generateSequence(1) { it + 1 }.map { "$base ($it)$ext" }.first { it.lowercase() !in taken }
        }
    }
}
