package app.volley.android.notifications

import android.app.Notification
import android.content.pm.PackageManager
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import app.volley.android.graph
import app.volley.android.protocol.Codec
import app.volley.android.protocol.MsgType
import app.volley.android.protocol.NotificationKey
import app.volley.android.protocol.NotificationPosted
import app.volley.android.protocol.bodyAs

/**
 * Mirrors phone notifications to the Mac. Its system binding also keeps the process
 * alive, so it owns the session lifecycle (no separate foreground service needed).
 */
class VolleyNotificationListener : NotificationListenerService() {

    /** key -> hash of last forwarded content; dedupes progress/update spam. Bounded LRU. */
    private val forwarded = object : LinkedHashMap<String, Int>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Int>) = size > MAX_TRACKED
    }
    private val appNames = HashMap<String, String>()

    override fun onListenerConnected() {
        val session = graph.session
        session.on(MsgType.NOTIFICATION_DISMISS) { env ->
            env.bodyAs<NotificationKey>()?.let { runCatching { cancelNotification(it.key) } }
        }
        session.start()
    }

    override fun onListenerDisconnected() {
        graph.session.off(MsgType.NOTIFICATION_DISMISS)
        graph.session.stop()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!shouldMirror(sbn)) return
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return

        val hash = 31 * title.hashCode() + text.hashCode()
        if (synchronized(forwarded) { forwarded[sbn.key] == hash }) return

        val body = NotificationPosted(sbn.key, sbn.packageName, appName(sbn.packageName), title, text, sbn.postTime)
        if (graph.session.send(Codec.encode(MsgType.NOTIFICATION_POSTED, body))) {
            synchronized(forwarded) { forwarded[sbn.key] = hash }
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val wasForwarded = synchronized(forwarded) { forwarded.remove(sbn.key) != null }
        if (wasForwarded) graph.session.send(Codec.encode(MsgType.NOTIFICATION_REMOVED, NotificationKey(sbn.key)))
    }

    private fun shouldMirror(sbn: StatusBarNotification): Boolean {
        val n = sbn.notification
        if (sbn.packageName == packageName) return false
        if (sbn.isOngoing || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        if (n.category in IGNORED_CATEGORIES) return false
        // SMS arrives through SmsReceiver; skip the SMS app's own notification to avoid duplicates.
        if (sbn.packageName == Telephony.Sms.getDefaultSmsPackage(this)) return false
        return true
    }

    private fun appName(pkg: String): String = appNames.getOrPut(pkg) {
        try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            pkg
        }
    }

    private companion object {
        const val MAX_TRACKED = 256
        val IGNORED_CATEGORIES = setOf(
            Notification.CATEGORY_PROGRESS,
            Notification.CATEGORY_SERVICE,
            Notification.CATEGORY_TRANSPORT,
            Notification.CATEGORY_SYSTEM,
        )
    }
}
