package net.icycloud.gxtodo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "net.icycloud.fdtodolist/alarms").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "initialize" -> {
                        AlarmStore.initialize(this)
                        result.success(null)
                    }
                    "status" -> result.success(mapOf("authorized" to AlarmStore.authorized(this)))
                    "authorize" -> authorize(result)
                    "snapshot" -> result.success(AlarmStore.snapshot(this))
                    "synchronize" -> {
                        @Suppress("UNCHECKED_CAST")
                        AlarmStore.synchronize(this, call.arguments as List<Map<String, Any>>)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("alarm", error.message ?: "闹钟设置失败", null)
            }
        }
    }

    private fun authorize(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            if (permissionResult != null) {
                result.error("permission", "请先完成当前权限设置", null)
                return
            }
            permissionResult = result
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 602)
            return
        }
        if (!getSystemService(NotificationManager::class.java).areNotificationsEnabled()) {
            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            result.error("permission", "请允许闹钟通知，返回后再次保存", null)
        } else if (!AlarmStore.exactAllowed(this)) {
            startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                Uri.parse("package:$packageName")))
            result.error("permission", "请允许“闹钟和提醒”，返回后再次保存", null)
        } else if (Build.VERSION.SDK_INT >= 34 &&
            !getSystemService(NotificationManager::class.java).canUseFullScreenIntent()) {
            startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                Uri.parse("package:$packageName")))
            result.error("permission", "请允许全屏闹钟，返回后再次保存", null)
        } else {
            result.success(null)
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code == 602) {
            val pending = permissionResult ?: return
            permissionResult = null
            if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) authorize(pending)
            else pending.error("permission", "需要允许闹钟通知才能启用提醒", null)
        }
    }

    override fun onDestroy() {
        permissionResult?.error("cancelled", "权限设置已取消，请重新保存", null)
        permissionResult = null
        super.onDestroy()
    }
}
