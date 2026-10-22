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

/** Watches the SMS provider and calls [onChange] once things settle (debounced). */
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

    @Synchronized
    fun start() {
        if (registered) return
        resolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, observer)
        registered = true
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
