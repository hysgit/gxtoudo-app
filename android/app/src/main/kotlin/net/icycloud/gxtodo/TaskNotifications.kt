package net.icycloud.gxtodo

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONObject
import net.icycloud.fdtodolist.R

object TaskNotifications {
    private const val CHANNEL = "task_notifications"
    private fun preferences(context: Context) =
        context.getSharedPreferences("task_notifications_v1", Context.MODE_PRIVATE)
    private fun read(context: Context) = JSONObject(preferences(context).getString("reminders", "{}")!!)
    private fun write(context: Context, entries: JSONObject) {
        check(preferences(context).edit().putString("reminders", entries.toString()).commit())
    }
    private fun alarms(context: Context) = context.getSystemService(AlarmManager::class.java)
    private fun notifications(context: Context) = context.getSystemService(NotificationManager::class.java)
    private fun pending(context: Context, id: String) = PendingIntent.getBroadcast(
        context, 0, Intent(context, TaskNotificationReceiver::class.java)
            .setData(Uri.parse("gxtodo-notification://show/${Uri.encode(id)}")).putExtra("id", id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun schedule(context: Context, id: String, at: Long) {
        val intent = pending(context, id)
        if (AlarmStore.exactAllowed(context)) {
            try {
                alarms(context).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
                return
            } catch (_: SecurityException) {
                // The user can revoke exact alarm permission during scheduling.
            }
        }
        alarms(context).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
    }

    @Synchronized fun synchronize(context: Context, desired: List<Map<String, Any>>) {
        val previous = read(context)
        val updated = JSONObject()
        for (entry in desired) {
            val id = entry["id"] as String
            val at = (entry["at"] as Number).toLong() * 1000
            if (previous.has(id) || at > System.currentTimeMillis()) updated.put(id, JSONObject(entry))
        }
        write(context, updated)
        for (id in previous.keys()) {
            if (!updated.has(id)) alarms(context).cancel(pending(context, id))
        }
        for (id in updated.keys()) {
            if (!previous.has(id)) schedule(context, id, updated.getJSONObject(id).getLong("at") * 1000)
        }
    }

    @Synchronized fun snapshot(context: Context): List<Map<String, Any>> {
        val entries = read(context)
        return entries.keys().asSequence().map { entries.getJSONObject(it) }
            .filter { it.getLong("at") * 1000 > System.currentTimeMillis() - 86_400_000 }
            .map { entry -> mapOf("id" to entry.getString("id"), "task" to entry.getString("task"),
                "occurrence" to entry.getLong("occurrence"), "at" to entry.getLong("at"),
                "title" to entry.getString("title")) }.toList()
    }

    @Synchronized fun restore(context: Context) {
        val entries = read(context)
        for (id in entries.keys()) {
            val at = entries.getJSONObject(id).getLong("at") * 1000
            if (at > System.currentTimeMillis()) schedule(context, id, at)
        }
    }

    @Synchronized fun show(context: Context, id: String) {
        val entries = read(context)
        val entry = entries.optJSONObject(id) ?: return
        entries.remove(id)
        write(context, entries)
        val manager = notifications(context)
        if (!manager.areNotificationsEnabled()) return
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "任务系统通知", NotificationManager.IMPORTANCE_HIGH))
            Notification.Builder(context, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setDefaults(Notification.DEFAULT_ALL)
        }
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify(id, 0, builder.setSmallIcon(R.drawable.ic_reminder)
            .setContentTitle(entry.getString("title")).setContentText("任务提醒")
            .setContentIntent(open).setAutoCancel(true).build())
    }
}

class TaskNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        TaskNotifications.show(context, id)
    }
}
