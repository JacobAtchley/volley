package app.volley.android.sms

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat

/** Digits only, last 10: "+1 (555) 123-4567" and "5551234567" compare equal. */
fun normalize(number: String): String = number.filter(Char::isDigit).takeLast(10)

/**
 * This phone's number, normalized: the SIM's number when Android shares it, else the one recipient that every
 * recent incoming MMS has in common. Null when neither is known (a single group message can't tell).
 */
fun ownNumberFrom(subscription: String?, inboxRecipientSets: List<Set<String>>): String? {
    subscription?.let(::normalize)?.takeIf { it.isNotEmpty() }?.let { return it }
    if (inboxRecipientSets.size < 2) return null
    return inboxRecipientSets
        .map { set -> set.map(::normalize).filter { it.isNotEmpty() }.toSet() }
        .reduce { acc, set -> acc intersect set }
        .singleOrNull()
}

/** Resolves and remembers this phone's number. The SIM number needs READ_PHONE_NUMBERS. */
class AndroidOwnNumber(
    private val context: Context,
    private val mms: ContentResolverMmsSource,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    @Volatile private var known: String? = null

    /** When the last lookup found nothing; retried after [RETRY_MS] (the permission may be granted later). */
    @Volatile private var missedAt = Long.MIN_VALUE / 2

    fun get(): String? {
        known?.let { return it }
        if (clock() - missedAt < RETRY_MS) return null
        return ownNumberFrom(subscriptionNumber(), mms.recentInboxRecipients()).also {
            if (it != null) known = it else missedAt = clock()
        }
    }

    // Used only to leave this phone out of group replies, never as a device identifier.
    @SuppressLint("HardwareIds")
    private fun subscriptionNumber(): String? {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_NUMBERS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) return null
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // The SIM often has no number recorded; the carrier or IMS registration usually does.
                val subs = context.getSystemService(SubscriptionManager::class.java)
                val subId = SubscriptionManager.getDefaultSmsSubscriptionId()
                listOf(
                    SubscriptionManager.PHONE_NUMBER_SOURCE_UICC,
                    SubscriptionManager.PHONE_NUMBER_SOURCE_CARRIER,
                    SubscriptionManager.PHONE_NUMBER_SOURCE_IMS,
                ).firstNotNullOfOrNull { source -> subs.getPhoneNumber(subId, source).takeIf { it.isNotBlank() } }
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(TelephonyManager::class.java).line1Number
            }
        } catch (e: SecurityException) {
            null
        }
    }

    private companion object {
        const val RETRY_MS = 10 * 60 * 1000L
    }
}
