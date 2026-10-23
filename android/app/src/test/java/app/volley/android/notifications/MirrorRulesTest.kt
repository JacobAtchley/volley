package app.volley.android.notifications

import android.app.Notification
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MirrorRulesTest {
    private val rules = MirrorRules(ownPackage = "app.volley.android", defaultSmsPackage = "com.sms", excluded = setOf("com.slack"))

    private fun facts(
        key: String = "k",
        pkg: String = "com.mail",
        channel: String? = "inbox",
        category: String? = null,
        ongoing: Boolean = false,
        summary: Boolean = false,
        title: String = "Order shipped",
        text: String = "Arrives Friday",
        postTime: Long = 1_000,
    ) = NotificationFacts(key, pkg, channel, category, ongoing, summary, title, text, postTime)

    @Test
    fun allowsOrdinaryNotification() = assertTrue(rules.allows(facts()))

    @Test
    fun rejectsOngoingSummaryAndIgnoredCategories() {
        assertFalse(rules.allows(facts(ongoing = true)))
        assertFalse(rules.allows(facts(summary = true)))
        listOf(Notification.CATEGORY_PROGRESS, Notification.CATEGORY_SERVICE, Notification.CATEGORY_TRANSPORT,
            Notification.CATEGORY_SYSTEM).forEach { assertFalse(it, rules.allows(facts(category = it))) }
    }

    @Test
    fun rejectsDefaultSmsApp() = assertFalse(rules.allows(facts(pkg = "com.sms")))

    @Test
    fun ownPackageOnlyOnTestChannel() {
        assertFalse(rules.allows(facts(pkg = "app.volley.android", channel = "other")))
        assertTrue(rules.allows(facts(pkg = "app.volley.android", channel = MirrorRules.TEST_CHANNEL)))
    }

    @Test
    fun rejectsExcludedPackage() = assertFalse(rules.allows(facts(pkg = "com.slack")))

    @Test
    fun toPosted_nullWhenTitleAndTextEmpty() {
        assertNull(facts(title = "", text = "").toPosted("Mail", rules))
        assertEquals("Mail", facts(title = "", text = "x").toPosted("Mail", rules)?.appName)
    }

    @Test
    fun removalAllowedWithoutPriorForward() {
        // Removal is decided by the rules alone, so it still works after the app restarts with an empty cache.
        assertTrue(rules.allows(facts(key = "never-forwarded")))
    }

    @Test
    fun batch_filtersBySinceTimeButActiveKeysCoverAllDays() {
        val batch = notificationBatch(listOf(facts(key = "old", postTime = 900), facts(key = "new", postTime = 1_100)),
            sinceTime = 1_000, rules = rules) { "Mail" }
        assertEquals(listOf("new"), batch.notifications.map { it.key })
        assertEquals(setOf("old", "new"), batch.activeKeys.toSet())
        assertTrue(batch.done)
    }

    @Test
    fun batch_excludesFilteredFromActiveKeys() {
        val batch = notificationBatch(listOf(facts(key = "a"), facts(key = "s", pkg = "com.slack")),
            sinceTime = 0, rules = rules) { it }
        assertEquals(listOf("a"), batch.activeKeys)
        assertEquals(listOf("a"), batch.notifications.map { it.key })
    }

    @Test
    fun batch_newestFirst() {
        val batch = notificationBatch(listOf(facts(key = "a", postTime = 1), facts(key = "b", postTime = 2)),
            sinceTime = 0, rules = rules) { it }
        assertEquals(listOf("b", "a"), batch.notifications.map { it.key })
    }
}
