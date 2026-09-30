package com.omnigodgeta.peak

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Android 10+ only lets an app capture the screen while a foreground service
 * of type mediaProjection is running. This one does nothing else: it shows
 * "Sharing your screen" for as long as a call is sharing, and stops when
 * the call stops sharing. Started from Dart (peak/screen_capture) after the
 * user has granted capture consent, as Android 14 requires.
 */
class ScreenCaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "Screen sharing",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val notification = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        })
            .setContentTitle("Peak")
            .setContentText("Sharing your screen in a call")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(ID, notification)
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL = "screen_share"
        private const val ID = 4242
    }
}
