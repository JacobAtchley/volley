package app.volley.android.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class FileServiceTest {
    @get:Rule val tmp = TemporaryFolder()

    private val root by lazy { tmp.newFolder("root") }
    private val service by lazy { DiskFileService(StoragePaths(root)) { _, _ -> byteArrayOf(1) } }

    private fun touch(path: String, bytes: Int = 1) = File(root, path).apply {
        parentFile!!.mkdirs()
        writeBytes(ByteArray(bytes))
    }

    @Test
    fun listSortsDirsFirstAndHidesDotfiles() {
        touch("b.txt", 3)
        touch("A.txt")
        touch(".hidden")
        File(root, "zdir").mkdir()
        val names = service.list("", showHidden = false).getOrThrow().map { it.name }
        assertEquals(listOf("zdir", "A.txt", "b.txt"), names)
        val b = service.list("", showHidden = false).getOrThrow().first { it.name == "b.txt" }
        assertEquals(3L, b.size)
        assertFalse(b.isDir)
        assertTrue(".hidden" in service.list("", showHidden = true).getOrThrow().map { it.name })
    }

    @Test
    fun listOmitsAndroidDataAndObb() {
        File(root, "Android/data").mkdirs()
        File(root, "Android/obb").mkdirs()
        File(root, "Android/media").mkdirs()
        assertEquals(listOf("media"), service.list("Android", showHidden = false).getOrThrow().map { it.name })
    }

    @Test
    fun listOfOutsidePathFails() = assertTrue(service.list("../", showHidden = false).isFailure)

    @Test
    fun deleteIsRecursiveAndReportsFailures() {
        touch("dir/sub/x.txt")
        touch("y.txt")
        val failed = service.delete(listOf("dir", "y.txt", "missing.txt", "../escape"))
        assertFalse(File(root, "dir").exists())
        assertFalse(File(root, "y.txt").exists())
        assertEquals(listOf("missing.txt", "../escape"), failed.map { it.path })
    }

    @Test
    fun createForUploadMakesDirsAndAvoidsClash() {
        touch("New/photo.jpg")
        val (name, out) = service.createForUpload("New", "photo.jpg").getOrThrow()
        out.use { it.write(byteArrayOf(7)) }
        assertEquals("photo (1).jpg", name)
        assertTrue(File(root, "New/photo (1).jpg").exists())
        val (deep, deepOut) = service.createForUpload("A/B/C", "x.bin").getOrThrow()
        deepOut.close()
        assertEquals("x.bin", deep)
        assertTrue(File(root, "A/B/C/x.bin").exists())
    }

    @Test
    fun openReadReturnsSize() {
        touch("v.mp4", 10)
        val (input, size) = service.openRead("v.mp4").getOrThrow()
        input.close()
        assertEquals(10L, size)
        assertTrue(service.openRead("nope.mp4").isFailure)
        assertTrue(service.openRead("").isFailure)
    }

    @Test
    fun discardRemovesFile() {
        touch("partial.bin")
        service.discard("partial.bin")
        assertFalse(File(root, "partial.bin").exists())
    }
}
