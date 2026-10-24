package app.volley.android.mms

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Fits photos into one MMS: scales to the carrier's (and our) maximum dimensions, then lowers JPEG quality
 * until every photo fits its share of [maxBytes]. Pure apart from the [Source.encode] callback.
 */
class ImageShrinker(private val maxBytes: Int, private val maxWidth: Int, private val maxHeight: Int) {
    /** A photo: its size, and how to render it as JPEG at a given size and quality. */
    class Source(val width: Int, val height: Int, val encode: (width: Int, height: Int, quality: Int) -> ByteArray)

    /** Target size keeping the aspect ratio: long side ≤ min(1600, carrier long side), short side ≤ carrier short side. */
    fun plan(width: Int, height: Int): Pair<Int, Int> {
        val longCap = min(MAX_LONG_SIDE, max(maxWidth, maxHeight)).toDouble()
        val shortCap = min(maxWidth, maxHeight).toDouble()
        val long = max(width, height).toDouble()
        val short = min(width, height).toDouble()
        val scale = minOf(1.0, longCap / long, shortCap / short)
        return (width * scale).roundToInt() to (height * scale).roundToInt()
    }

    fun shrink(photos: List<Source>): Result<List<ByteArray>> = runCatching {
        val budget = maxBytes / photos.size.coerceAtLeast(1)
        photos.map { photo ->
            val (w, h) = plan(photo.width, photo.height)
            QUALITIES.asSequence().map { photo.encode(w, h, it) }.firstOrNull { it.size <= budget }
                ?: throw IllegalStateException("Photo too large to send by MMS")
        }
    }

    private companion object {
        const val MAX_LONG_SIDE = 1600
        val QUALITIES = listOf(85, 70, 55, 40)
    }
}
