package net.icycloud.gxtodo

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject
import net.icycloud.fdtodolist.R

object TaskNotifications {
    const val CHANNEL = "task_remote_push"

    fun initialize(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "任务远程推送", NotificationManager.IMPORTANCE_HIGH))
        }
        val legacy = context.getSharedPreferences("task_notifications_v1", Context.MODE_PRIVATE)
        val entries = JSONObject(legacy.getString("reminders", "{}") ?: "{}")
        val alarms = context.getSystemService(AlarmManager::class.java)
        for (id in entries.keys()) {
            val old = Intent().setClassName(context, "net.icycloud.gxtodo.TaskNotificationReceiver")
                .setData(Uri.parse("gxtodo-notification://show/${Uri.encode(id)}"))
            val pending = PendingIntent.getBroadcast(context, 0, old,
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
            if (pending != null) { alarms.cancel(pending); pending.cancel() }
        }
        legacy.edit().remove("reminders").apply()
    }
}

class TodoFirebaseMessaging : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val content = message.notification ?: return
        val manager = getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return
        TaskNotifications.initialize(this)
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, TaskNotifications.CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setDefaults(Notification.DEFAULT_ALL)
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify(message.data["task_push_tag"], 0, builder.setSmallIcon(R.drawable.ic_reminder)
            .setContentTitle(content.title).setContentText(content.body).setAutoCancel(true)
            .setContentIntent(open).build())
    }
}
