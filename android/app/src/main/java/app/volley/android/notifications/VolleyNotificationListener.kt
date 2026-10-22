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
import app.volley.android.protocol.NotificationSync
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
        session.on(MsgType.NOTIFICATION_SYNC) { env ->
            val req = env.bodyAs<NotificationSync>() ?: return@on
            val active = runCatching { activeNotifications.orEmpty().map(::facts) }.getOrDefault(emptyList())
            session.send(Codec.encode(MsgType.NOTIFICATION_BATCH, notificationBatch(active, req.sinceTime, rules(), ::appName)))
        }
        session.start()
    }

    override fun onListenerDisconnected() {
        graph.session.off(MsgType.NOTIFICATION_DISMISS)
        graph.session.off(MsgType.NOTIFICATION_SYNC)
        graph.session.stop()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val f = facts(sbn)
        val body = f.toPosted(appName(f.pkg), rules()) ?: return

        val hash = 31 * f.title.hashCode() + f.text.hashCode()
        if (synchronized(forwarded) { forwarded[sbn.key] == hash }) return

        if (graph.session.send(Codec.encode(MsgType.NOTIFICATION_POSTED, body))) {
            synchronized(forwarded) { forwarded[sbn.key] = hash }
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        synchronized(forwarded) { forwarded.remove(sbn.key) }
        // Decided by the rules, not the forwarded cache: the Mac may know it from a sync or an earlier run.
        if (rules().allows(facts(sbn))) {
            graph.session.send(Codec.encode(MsgType.NOTIFICATION_REMOVED, NotificationKey(sbn.key)))
        }
    }

    private fun rules() = MirrorRules(packageName, Telephony.Sms.getDefaultSmsPackage(this), graph.excludedPackages.current)

    private fun facts(sbn: StatusBarNotification): NotificationFacts {
        val n = sbn.notification
        val extras = n.extras
        return NotificationFacts(
            key = sbn.key,
            pkg = sbn.packageName,
            channelId = n.channelId,
            category = n.category,
            ongoing = sbn.isOngoing,
            groupSummary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0,
            title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty(),
            text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty(),
            postTime = sbn.postTime,
        )
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
    }
}
