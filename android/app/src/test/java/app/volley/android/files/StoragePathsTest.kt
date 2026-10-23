package app.volley.android.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class StoragePathsTest {
    @get:Rule val tmp = TemporaryFolder()

    private val root by lazy { tmp.newFolder("root") }
    private val paths by lazy { StoragePaths(root) }

    @Test
    fun resolvesInsideRoot() {
        File(root, "Pictures").mkdir()
        assertEquals(File(root, "Pictures").canonicalFile, paths.resolve("Pictures"))
        assertEquals(root.canonicalFile, paths.resolve(""))
        assertEquals("Pictures/a.jpg", paths.relativeOf(File(root, "Pictures/a.jpg")))
    }

    @Test
    fun rejectsTraversal() {
        listOf("../x", "a/../../x", "/etc/passwd", "Pictures/../../outside").forEach {
            assertNull(it, paths.resolve(it))
        }
        assertNotNull(paths.resolve("Pictures/../Download"))
    }

    @Test
    fun rejectsSymlinkEscape() {
        val outside = tmp.newFolder("outside")
        Files.createSymbolicLink(File(root, "link").toPath(), outside.toPath())
        assertNull(paths.resolve("link"))
        assertNull(paths.resolve("link/secret.txt"))
    }

    @Test
    fun androidPrivateDirsAreHidden() {
        assertTrue(paths.isHiddenSystemDir("Android/data"))
        assertTrue(paths.isHiddenSystemDir("Android/obb"))
        assertEquals(false, paths.isHiddenSystemDir("Android/media"))
        assertNull(paths.resolve("Android/data/com.app/x"))
    }

    @Test
    fun uniqueNameAndroidStyle() {
        assertEquals("photo.jpg", StoragePaths.uniqueName(emptySet(), "photo.jpg"))
        assertEquals("photo (2).jpg", StoragePaths.uniqueName(setOf("photo.jpg", "photo (1).jpg"), "photo.jpg"))
    }

    @Test
    fun uniqueNameHandlesNoExtensionAndDotfiles() {
        assertEquals("README (1)", StoragePaths.uniqueName(setOf("README"), "README"))
        assertEquals(".nomedia (1)", StoragePaths.uniqueName(setOf(".nomedia"), ".nomedia"))
        assertEquals("a.tar (1).gz", StoragePaths.uniqueName(setOf("a.tar.gz"), "a.tar.gz"))
    }
}
