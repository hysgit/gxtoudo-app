package net.icycloud.gxtodo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log

class AlarmSoundService : Service() {
    companion object {
        private const val CHANNEL = "task_alarm_ringing"
        private const val NOTIFICATION = 8701
        var instance: AlarmSoundService? = null
            private set
        fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= 26) {
                val channel = NotificationChannel(CHANNEL, "任务闹钟", NotificationManager.IMPORTANCE_HIGH)
                channel.setSound(null, null)
                channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
            }
        }
    }
    private val handler = Handler(Looper.getMainLooper())
    private val active = linkedMapOf<String, Pair<String, Runnable>>()
    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var focus: AudioFocusRequest? = null
    private val audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "dismiss") {
            active.keys.toList().forEach { AlarmStore.dismiss(this, it) }
            if (active.isEmpty()) stopSelf()
            return START_NOT_STICKY
        }
        val id = intent?.getStringExtra("id") ?: run { stopSelf(); return START_NOT_STICKY }
        val title = intent.getStringExtra("title") ?: "任务闹钟"
        active.remove(id)?.let { handler.removeCallbacks(it.second) }
        val timeout = Runnable { remove(id) }
        active[id] = title to timeout
        startForeground(NOTIFICATION, notification())
        handler.postDelayed(timeout, 60_000)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gxtodo:alarm").apply { acquire(65_000) }
        play()
        sendBroadcast(Intent("$packageName.ALARM_CHANGED").setPackage(packageName))
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val screen = PendingIntent.getActivity(this, 1, Intent(this, AlarmActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 2, Intent(this, AlarmSoundService::class.java).setAction("dismiss"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        return builder.setSmallIcon(net.icycloud.fdtodolist.R.drawable.ic_reminder)
            .setContentTitle("高效Todo 闹钟")
            .setContentText(active.values.joinToString("、") { it.first })
            .setCategory(Notification.CATEGORY_ALARM).setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true).setContentIntent(screen).setFullScreenIntent(screen, true)
            .addAction(Notification.Action.Builder(null, "关闭闹钟", stop).build()).build()
    }

    private fun play() {
        if (player != null) return
        val audio = getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(audioAttributes).setOnAudioFocusChangeListener { }.build()
            audio.requestAudioFocus(focus!!)
        }
        val sound = MediaPlayer()
        try {
            sound.apply {
                setAudioAttributes(audioAttributes)
                setDataSource(this@AlarmSoundService, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM))
                isLooping = true
                prepare()
                start()
            }
            player = sound
        } catch (error: Exception) {
            sound.release()
            player = null
            Log.e("TodoAlarm", "Alarm audio could not start", error)
        }
        @Suppress("DEPRECATION")
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (Build.VERSION.SDK_INT >= 26) vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 600, 400), 0))
        else vibrator.vibrate(longArrayOf(0, 600, 400), 0)
    }

    fun ringing(): List<Pair<String, String>> = active.map { it.key to it.value.first }

    fun remove(id: String) {
        active.remove(id)?.let { handler.removeCallbacks(it.second) }
        sendBroadcast(Intent("$packageName.ALARM_CHANGED").setPackage(packageName))
        if (active.isEmpty()) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } else getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        active.clear()
        player?.stop()
        player?.release()
        @Suppress("DEPRECATION")
        (getSystemService(Context.VIBRATOR_SERVICE) as Vibrator).cancel()
        if (Build.VERSION.SDK_INT >= 26) focus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }
        wakeLock?.let { if (it.isHeld) it.release() }
        instance = null
        sendBroadcast(Intent("$packageName.ALARM_CHANGED").setPackage(packageName))
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
