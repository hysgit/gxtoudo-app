package net.icycloud.gxtodo

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

class AlarmActivity : Activity() {
    private val changes = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = render()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        else window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val filter = IntentFilter("$packageName.ALARM_CHANGED")
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(changes, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(changes, filter)
        render()
    }
    private fun render() {
        val alarms = AlarmSoundService.instance?.ringing().orEmpty()
        if (alarms.isEmpty()) { finish(); return }
        val density = resources.displayMetrics.density
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding((28*density).toInt(), (28*density).toInt(), (28*density).toInt(), (28*density).toInt())
            setBackgroundColor(Color.rgb(245, 247, 252))
        }
        content.addView(TextView(this).apply { text = "高效Todo 闹钟"; textSize = 28f; setTextColor(Color.rgb(30, 40, 60)) })
        for ((id, title) in alarms) {
            content.addView(TextView(this).apply { text = title; textSize = 24f; gravity = Gravity.CENTER; setPadding(0, 40, 0, 24) })
            content.addView(Button(this).apply { text = "关闭闹钟"; setOnClickListener { AlarmStore.dismiss(this@AlarmActivity, id) } })
        }
        content.addView(TextView(this).apply { text = "本次响铃 1 分钟，未关闭每 10 分钟再响"; setPadding(0, 32, 0, 0) })
        setContentView(content)
    }
    override fun onDestroy() { unregisterReceiver(changes); super.onDestroy() }
}
