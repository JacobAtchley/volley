package app.volley.android.mms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageShrinkerTest {
    @Test
    fun planKeepsAspectWithinMaxDims() {
        val s = ImageShrinker(maxBytes = 1_000_000, maxWidth = 2592, maxHeight = 1944)
        assertEquals(1600 to 1200, s.plan(4000, 3000))
        assertEquals(1200 to 1600, s.plan(3000, 4000))
        assertEquals(800 to 600, s.plan(800, 600))
        val small = ImageShrinker(maxBytes = 300_000, maxWidth = 640, maxHeight = 480)
        assertEquals(640 to 480, small.plan(4000, 3000))
    }

    @Test
    fun shrinkStepsQualityUntilItFits() {
        val tried = mutableListOf<Int>()
        val s = ImageShrinker(maxBytes = 100, maxWidth = 1600, maxHeight = 1600)
        // Size falls with quality: 85→150 B, 70→120 B, 55→90 B; the budget is 100 B.
        val out = s.shrink(
            listOf(
                ImageShrinker.Source(4000, 3000) { _, _, q ->
                    tried += q
                    ByteArray(q * 2 - 20)
                },
            ),
        )
        assertEquals(listOf(85, 70, 55), tried)
        assertEquals(90, out.getOrThrow().single().size)
    }

    @Test
    fun shrinkSplitsTheBudgetAcrossPhotos() {
        val s = ImageShrinker(maxBytes = 200, maxWidth = 1600, maxHeight = 1600)
        val out = s.shrink(List(2) { ImageShrinker.Source(100, 100) { _, _, q -> ByteArray(q + 10) } })
        assertTrue(out.getOrThrow().sumOf { it.size } <= 200)
    }

    @Test
    fun shrinkFailsWhenItCannotFit() {
        val s = ImageShrinker(maxBytes = 10, maxWidth = 1600, maxHeight = 1600)
        val out = s.shrink(listOf(ImageShrinker.Source(100, 100) { _, _, _ -> ByteArray(1_000) }))
        assertEquals("Photo too large to send by MMS", out.exceptionOrNull()?.message)
    }
}
