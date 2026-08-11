package com.safelens.smart_glasses_detection

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.safelens/monitor"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startMonitoring" -> {
                        startMonitoring()
                        result.success(true)
                    }
                    "stopMonitoring" -> {
                        stopMonitoring()
                        result.success(true)
                    }
                    "isMonitoring" -> {
                        result.success(CameraMonitorService.monitoringActive)
                    }
                    "consumePendingAlarm" -> {
                        result.success(consumePendingAlarm())
                    }
                    "setAppUsingCamera" -> {
                        val using = call.argument<Boolean>("using") ?: false
                        CameraMonitorService.appUsingCamera = using
                        result.success(true)
                    }
                    "sos" -> {
                        AlarmEngine.trigger(this)
                        result.success(true)
                    }
                    "stopAlarm" -> {
                        AlarmEngine.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startMonitoring() {
        val intent = Intent(this, CameraMonitorService::class.java)
        ContextCompat.startForegroundService(this, intent)
    }

    private fun stopMonitoring() {
        val intent = Intent(this, CameraMonitorService::class.java)
            .setAction(CameraMonitorService.ACTION_STOP)
        startService(intent)
    }

    private fun consumePendingAlarm(): Boolean {
        val prefs = getSharedPreferences(AlarmEngine.PREFS, Context.MODE_PRIVATE)
        val pending = prefs.getBoolean(AlarmEngine.KEY_PENDING, false)
        if (pending) {
            prefs.edit().remove(AlarmEngine.KEY_PENDING).apply()
        }
        return pending
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}
