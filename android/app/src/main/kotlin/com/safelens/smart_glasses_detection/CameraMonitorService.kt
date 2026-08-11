package com.safelens.smart_glasses_detection

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import androidx.core.app.NotificationCompat

class CameraMonitorService : Service() {

    companion object {
        const val TAG = "CameraMonitorService"

        const val CHANNEL_FOREGROUND = "safelens_monitor_channel"
        const val CHANNEL_ALARM = "safelens_alarm_channel"
        const val NOTIFICATION_ID = 1001
        const val ALARM_NOTIFICATION_ID = 1002

        const val ACTION_STOP = "com.safelens.smart_glasses_detection.STOP_MONITOR"
        const val EXTRA_TRIGGER_ALARM = "extra_trigger_alarm"

        private const val ALARM_COOLDOWN_MS = 12000L

        @Volatile
        var monitoringActive = false
            private set

        @Volatile
        var alarmInCooldown = false
            private set

        @Volatile
        var appUsingCamera = false
    }

    private val handler = Handler(Looper.getMainLooper())
    private var cameraManager: CameraManager? = null
    private var callbackRegistered = false

    private val availabilityCallback = object : CameraManager.AvailabilityCallback() {
        override fun onCameraUnavailable(cameraId: String) {
            super.onCameraUnavailable(cameraId)
            Log.i(TAG, "Camera $cameraId became unavailable (in use)")
            if (monitoringActive && !appUsingCamera) {
                triggerAlarm()
            }
        }

        override fun onCameraAvailable(cameraId: String) {
            super.onCameraAvailable(cameraId)
            Log.i(TAG, "Camera $cameraId became available")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            AlarmEngine.stop(this)
            stopMonitoring()
            return START_NOT_STICKY
        }
        if (!monitoringActive) {
            monitoringActive = true
            startForeground(NOTIFICATION_ID, buildMonitorNotification())
            registerCameraCallback()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        unregisterCameraCallback()
        monitoringActive = false
        AlarmEngine.stop(this)
        super.onDestroy()
    }

    private fun registerCameraCallback() {
        if (!callbackRegistered) {
            try {
                cameraManager?.registerAvailabilityCallback(availabilityCallback, handler)
                callbackRegistered = true
                Log.i(TAG, "Camera availability callback registered successfully.")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register camera availability callback", e)
            }
        }
    }

    private fun unregisterCameraCallback() {
        if (callbackRegistered) {
            try {
                cameraManager?.unregisterAvailabilityCallback(availabilityCallback)
                callbackRegistered = false
                Log.i(TAG, "Camera availability callback unregistered.")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to unregister camera availability callback", e)
            }
        }
    }

    private fun stopMonitoring() {
        unregisterCameraCallback()
        monitoringActive = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun triggerAlarm() {
        if (alarmInCooldown) return
        alarmInCooldown = true
        handler.postDelayed({ alarmInCooldown = false }, ALARM_COOLDOWN_MS)

        Log.i(TAG, "Camera switched on -> triggering safety alarm")
        AlarmEngine.trigger(this)
    }

    private fun createNotificationChannels() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val monitorChannel = NotificationChannel(
                CHANNEL_FOREGROUND,
                "Safety Monitoring",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows that camera safety monitoring is active"
                setShowBadge(false)
            }
            nm.createNotificationChannel(monitorChannel)

            val alarmChannel = NotificationChannel(
                CHANNEL_ALARM,
                "Safety Alarm",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alerts when the camera is switched on"
                setShowBadge(true)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setSound(null, null)
            }
            nm.createNotificationChannel(alarmChannel)
        }
    }

    private fun buildMonitorNotification(): Notification {
        val stopIntent = PendingIntent.getService(
            this,
            0,
            Intent(this, CameraMonitorService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_FOREGROUND)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("SafeSight Protection Active")
            .setContentText("Monitoring camera status for your safety.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(0, "Stop Protection", stopIntent)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE
                )
            )
            .build()
    }
}

/**
 * Central alarm engine: vibrates, keeps the screen on,
 * and shows a full-screen intent alarm notification.
 */
object AlarmEngine {

    const val TAG = "AlarmEngine"
    const val PREFS = "safelens_alarm"
    const val KEY_PENDING = "alarm_pending"

    @Volatile
    var isAlarming = false
        private set

    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var autoStopRunnable: Runnable? = null

    fun trigger(context: Context) {
        if (isAlarming) return

        isAlarming = true

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().putBoolean(KEY_PENDING, true).apply()

        // Vibration and on-screen alert only (no default audio sound played)
        startVibration(context)
        acquireWakeLock(context)
        showAlarmNotification(context)

        // Bring the full-screen Flutter alarm UI to the front
        try {
            val launchIntent = Intent(context, MainActivity::class.java)
            launchIntent.action = Intent.ACTION_MAIN
            launchIntent.addCategory(Intent.CATEGORY_LAUNCHER)
            launchIntent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            launchIntent.putExtra(CameraMonitorService.EXTRA_TRIGGER_ALARM, true)
            context.startActivity(launchIntent)
        } catch (e: Exception) {
            Log.e(TAG, "Could not launch alarm screen", e)
        }

        // Auto stop after 45s
        val handler = Handler(Looper.getMainLooper())
        autoStopRunnable?.let { handler.removeCallbacks(it) }
        autoStopRunnable = Runnable { stop(context) }
        handler.postDelayed(autoStopRunnable!!, 45_000L)
    }

    fun stop(context: Context) {
        if (!isAlarming) return
        isAlarming = false

        stopVibration()
        releaseWakeLock()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(CameraMonitorService.ALARM_NOTIFICATION_ID)

        autoStopRunnable?.let { runnable ->
            Handler(Looper.getMainLooper()).removeCallbacks(runnable)
            autoStopRunnable = null
        }
    }

    private fun startVibration(context: Context) {
        val vibratorService = context.getSystemService(Context.VIBRATOR_SERVICE)
        if (vibratorService is Vibrator) {
            vibrator = vibratorService
            val pattern = longArrayOf(0, 450, 250, 450, 250, 450, 900)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibratorService.vibrate(
                    VibrationEffect.createWaveform(pattern, 0)
                )
            } else {
                @Suppress("DEPRECATION")
                vibratorService.vibrate(pattern, 0)
            }
        }
    }

    private fun stopVibration() {
        try {
            vibrator?.cancel()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping vibration", e)
        }
        vibrator = null
    }

    private fun acquireWakeLock(context: Context) {
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            wakeLock = pm.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "SafeLens:Alarm"
            ).apply { acquire(45_000L) }
        } catch (e: Exception) {
            Log.e(TAG, "Could not acquire wake lock", e)
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock", e)
        }
        wakeLock = null
    }

    private fun showAlarmNotification(context: Context) {
        val resultIntent = Intent(context, MainActivity::class.java)
        resultIntent.action = Intent.ACTION_MAIN
        resultIntent.addCategory(Intent.CATEGORY_LAUNCHER)
        resultIntent.putExtra(CameraMonitorService.EXTRA_TRIGGER_ALARM, true)
        resultIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        val fullScreenPendingIntent = PendingIntent.getActivity(
            context,
            1,
            resultIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val contentPendingIntent = PendingIntent.getActivity(
            context,
            2,
            resultIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = NotificationCompat.Builder(context, CameraMonitorService.CHANNEL_ALARM)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("SAFE ALERT - Camera Active")
            .setContentText("Camera access has been detected. Tap to open SafeSight.")
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setOngoing(true)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .setContentIntent(contentPendingIntent)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(CameraMonitorService.ALARM_NOTIFICATION_ID, notification)
    }
}
