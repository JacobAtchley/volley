package app.volley.android.sms

import android.content.ContentResolver
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Watches the SMS and MMS providers and calls [onChange] once things settle (debounced). */
class SmsObserver(
    private val resolver: ContentResolver,
    private val scope: CoroutineScope,
    private val onChange: () -> Unit,
) {
    private var pending: Job? = null
    private var registered = false

    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            synchronized(this@SmsObserver) {
                pending?.cancel()
                pending = scope.launch {
                    delay(DEBOUNCE_MS)
                    onChange()
                }
            }
        }
    }

    /** Does nothing without READ_SMS; registering would throw and take the process down. */
    @Synchronized
    fun start() {
        if (registered) return
        registered = try {
            resolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, observer)
            resolver.registerContentObserver(Telephony.Mms.CONTENT_URI, true, observer)
            // Some Android versions announce MMS changes only on the combined URI.
            resolver.registerContentObserver(Telephony.MmsSms.CONTENT_URI, true, observer)
            true
        } catch (e: SecurityException) {
            false
        }
    }

    @Synchronized
    fun stop() {
        if (!registered) return
        resolver.unregisterContentObserver(observer)
        pending?.cancel()
        registered = false
    }

    private companion object {
        const val DEBOUNCE_MS = 1_000L
    }
}
