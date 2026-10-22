package app.volley.android.notifications

import android.app.Notification
import app.volley.android.protocol.NotificationBatch
import app.volley.android.protocol.NotificationPosted

/** What we need from a `StatusBarNotification`, as plain data so the rules can be unit-tested. */
data class NotificationFacts(
    val key: String,
    val pkg: String,
    val channelId: String?,
    val category: String?,
    val ongoing: Boolean,
    val groupSummary: Boolean,
    val title: String,
    val text: String,
    val postTime: Long,
)

/** Which notifications get mirrored to the Mac. One place for live posts, removals and sync. */
class MirrorRules(
    val ownPackage: String,
    val defaultSmsPackage: String?,
    val excluded: Set<String>,
) {
    fun allows(f: NotificationFacts): Boolean {
        if (f.pkg == ownPackage) return f.channelId == TEST_CHANNEL
        if (f.ongoing || f.groupSummary) return false
        if (f.category in IGNORED_CATEGORIES) return false
        // SMS arrives through SmsReceiver; skip the SMS app's own notification to avoid duplicates.
        if (f.pkg == defaultSmsPackage) return false
        return f.pkg !in excluded
    }

    companion object {
        const val TEST_CHANNEL = "volley_test"
        private val IGNORED_CATEGORIES = setOf(
            Notification.CATEGORY_PROGRESS,
            Notification.CATEGORY_SERVICE,
            Notification.CATEGORY_TRANSPORT,
            Notification.CATEGORY_SYSTEM,
        )
    }
}

fun NotificationFacts.toPosted(appName: String, rules: MirrorRules): NotificationPosted? {
    if (!rules.allows(this) || (title.isEmpty() && text.isEmpty())) return null
    return NotificationPosted(key, pkg, appName, title, text, postTime)
}

/** Answer to `notification.sync`: today's mirrorable notifications plus every mirrorable key still showing. */
fun notificationBatch(
    active: List<NotificationFacts>,
    sinceTime: Long,
    rules: MirrorRules,
    appName: (String) -> String,
): NotificationBatch {
    val allowed = active.filter(rules::allows)
    val recent = allowed.filter { it.postTime >= sinceTime }
        .sortedByDescending { it.postTime }
        .mapNotNull { it.toPosted(appName(it.pkg), rules) }
    return NotificationBatch(recent, allowed.map { it.key }, done = true)
}
