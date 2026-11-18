package net.icycloud.gxtodo

import android.app.AlarmManager
import android.media.MediaPlayer
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AlarmLifecycleTest {
    private fun awaitCondition(timeout: Long, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            Thread.sleep(200)
        }
        assertTrue("Timed out after $timeout ms", condition())
    }

    @Test fun ringsForOneMinuteRepeatsAfterTenMinutesAndStopsWhenDismissed() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val previous = AlarmStore.snapshot(context)
        val at = System.currentTimeMillis() / 1000 + 5
        val id = "alarm-timing-instrumentation-$at"
        val event = mapOf("id" to id, "task" to "instrumentation", "occurrence" to at,
            "at" to at, "title" to "闹钟时序验证")
        val manager = context.getSystemService(AlarmManager::class.java)
        fun ringing(): Boolean {
            var active = false
            instrumentation.runOnMainSync { active = AlarmSoundService.instance?.ringing()?.any { it.first == id } == true }
            return active
        }
        try {
            AlarmStore.initialize(context)
            AlarmStore.synchronize(context, previous + event)
            awaitCondition(20_000, ::ringing)
            instrumentation.runOnMainSync {
                val service = AlarmSoundService.instance!!
                val audioField = AlarmSoundService::class.java.getDeclaredField("player").apply { isAccessible = true }
                assertTrue("Alarm audio must be playing", (audioField.get(service) as? MediaPlayer)?.isPlaying == true)
            }
            assertEquals("Next ring keeps the original ten-minute cadence", at * 1000 + 600_000,
                manager.nextAlarmClock.triggerTime)
            awaitCondition(70_000) { !ringing() }
            assertTrue("Automatic timeout must retain the repeating alarm", AlarmStore.snapshot(context).any { it["id"] == id })
            assertEquals(at * 1000 + 600_000, manager.nextAlarmClock.triggerTime)
            awaitCondition(560_000, ::ringing)
            assertEquals(at * 1000 + 1_200_000, manager.nextAlarmClock.triggerTime)
            instrumentation.runOnMainSync { AlarmStore.dismiss(context, id) }
            awaitCondition(5_000) { !ringing() }
            assertFalse(AlarmStore.snapshot(context).any { it["id"] == id })
            assertNotEquals("Dismiss cancels the third ring", at * 1000 + 1_200_000,
                manager.nextAlarmClock?.triggerTime ?: 0)
        } finally {
            instrumentation.runOnMainSync { AlarmStore.dismiss(context, id) }
            AlarmStore.synchronize(context, previous)
        }
    }
}
