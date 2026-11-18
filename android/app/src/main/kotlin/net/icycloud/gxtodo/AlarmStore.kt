package net.icycloud.gxtodo

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONObject

object AlarmStore {
    const val INTERVAL = 600_000L
    private fun preferences(context: Context) =
        context.getSharedPreferences("task_alarms_v1", Context.MODE_PRIVATE)
    private fun read(context: Context) = JSONObject(preferences(context).getString("alarms", "{}")!!)
    private fun write(context: Context, alarms: JSONObject) {
        check(preferences(context).edit().putString("alarms", alarms.toString()).commit()) {
            "无法保存闹钟，请检查设备存储空间"
        }
    }
    private fun manager(context: Context) = context.getSystemService(AlarmManager::class.java)
    fun exactAllowed(context: Context) = Build.VERSION.SDK_INT < 31 || manager(context).canScheduleExactAlarms()
    fun authorized(context: Context) = exactAllowed(context) &&
        context.getSystemService(NotificationManager::class.java).areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 34 || context.getSystemService(NotificationManager::class.java).canUseFullScreenIntent())

    @Synchronized fun initialize(context: Context) {
        if (!preferences(context).getBoolean("migrated", false)) {
            context.getSystemService(NotificationManager::class.java).cancelAll()
            preferences(context).edit().putBoolean("migrated", true).commit()
        }
        AlarmSoundService.createChannel(context)
    }

    private fun pending(context: Context, id: String) = PendingIntent.getBroadcast(
        context, 0,
        Intent(context, TaskAlarmReceiver::class.java)
            .setData(Uri.parse("gxtodo-alarm://ring/${Uri.encode(id)}"))
            .putExtra("id", id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun schedule(context: Context, id: String, at: Long) {
        val show = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager(context).setAlarmClock(AlarmManager.AlarmClockInfo(at, show), pending(context, id))
    }

    @Synchronized fun snapshot(context: Context): List<Map<String, Any>> {
        val alarms = read(context)
        return alarms.keys().asSequence().map { alarms.getJSONObject(it) }
            .filter { !it.optBoolean("dismissed") }
            .map { alarm -> mapOf("id" to alarm.getString("id"), "task" to alarm.getString("task"),
                "occurrence" to alarm.getLong("occurrence"), "at" to alarm.getLong("at"),
                "title" to alarm.getString("title")) }.toList()
    }

    @Synchronized fun synchronize(context: Context, desired: List<Map<String, Any>>) {
        check(authorized(context)) { "请检查系统闹钟、通知和全屏提醒权限" }
        val previous = read(context)
        val updated = JSONObject()
        for (value in desired) {
            val id = value["id"] as String
            val old = previous.optJSONObject(id)
            val alarm = JSONObject(value)
            alarm.put("dismissed", old?.optBoolean("dismissed") ?: false)
            alarm.put("nextAt", old?.optLong("nextAt") ?: (alarm.getLong("at") * 1000))
            updated.put(id, alarm)
        }
        write(context, updated)
        for (id in previous.keys()) {
            if (!updated.has(id)) {
                manager(context).cancel(pending(context, id))
                AlarmSoundService.instance?.remove(id)
            }
        }
        for (id in updated.keys()) {
            val alarm = updated.getJSONObject(id)
            if (!alarm.getBoolean("dismissed")) {
                schedule(context, id, maxOf(System.currentTimeMillis() + 1000, alarm.getLong("nextAt")))
            }
        }
    }

    @Synchronized fun ring(context: Context, id: String): String? {
        if (!authorized(context)) return null
        val alarms = read(context)
        val alarm = alarms.optJSONObject(id) ?: return null
        if (alarm.optBoolean("dismissed")) return null
        val now = System.currentTimeMillis()
        val expected = alarm.getLong("nextAt")
        // Ignore an already-delivered broadcast after its next occurrence was registered.
        if (expected > now + 2000) return null
        val next = expected + ((maxOf(0, now - expected) / INTERVAL) + 1) * INTERVAL
        alarm.put("nextAt", next)
        write(context, alarms)
        schedule(context, id, next)
        return alarm.getString("title")
    }

    @Synchronized fun dismiss(context: Context, id: String) {
        val alarms = read(context)
        alarms.optJSONObject(id)?.put("dismissed", true)
        write(context, alarms)
        manager(context).cancel(pending(context, id))
        AlarmSoundService.instance?.remove(id)
    }

    @Synchronized fun restore(context: Context) {
        initialize(context)
        if (!authorized(context)) return
        val alarms = read(context)
        for (id in alarms.keys()) {
            val alarm = alarms.getJSONObject(id)
            if (!alarm.optBoolean("dismissed")) {
                schedule(context, id, maxOf(System.currentTimeMillis() + 2000, alarm.getLong("nextAt")))
            }
        }
    }
}

class TaskAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val title = AlarmStore.ring(context, id) ?: return
        val service = Intent(context, AlarmSoundService::class.java).putExtra("id", id).putExtra("title", title)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service)
        else context.startService(service)
    }
}

class AlarmRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED)) AlarmStore.restore(context)
    }
}
