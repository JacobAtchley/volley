package app.volley.android.notifications

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import java.text.DateFormat
import java.util.Date

/** Posts a notification that Volley mirrors, so the Mac side can be tried out on demand. */
object TestNotifications {
    fun post(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(MirrorRules.TEST_CHANNEL, "Test notifications", NotificationManager.IMPORTANCE_DEFAULT),
        )
        val time = DateFormat.getTimeInstance(DateFormat.MEDIUM).format(Date())
        val notification = Notification.Builder(context, MirrorRules.TEST_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle("Volley test")
            .setContentText("Test notification $time")
            .setAutoCancel(true)
            .build()
        // A new id per tap, so each one is its own notification (and its own history row on the Mac).
        manager.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), notification)
    }
}
