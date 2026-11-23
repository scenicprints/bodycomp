package com.scenicprints.bodycomp.wear

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.health.services.client.HealthServices
import androidx.health.services.client.PassiveListenerService
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.PassiveListenerConfig
import kotlin.math.roundToInt

// ═══════════════════════════════════════════════════════════════════════
//  Reads the watch's own "calories burned today" (Health Services
//  CALORIES_DAILY: active + resting, resetting at local midnight) and keeps
//  CalorieStore current, so the watch face can show eaten vs. burned.
//
//  Needs the ACTIVITY_RECOGNITION permission, which RunActivity asks for the
//  first time BodyComp is opened on the watch. The registration does not
//  survive a reboot, so BootReceiver re-registers.
// ═══════════════════════════════════════════════════════════════════════

object HealthLink {
    @Volatile
    private var registered = false

    fun hasPermission(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED

    /** Idempotent and silent: safe to call from anywhere, any number of times. */
    fun ensureRegistered(context: Context) {
        if (registered || !hasPermission(context)) {
            return
        }
        try {
            val config = PassiveListenerConfig.builder()
                .setDataTypes(setOf(DataType.CALORIES_DAILY))
                .build()
            HealthServices.getClient(context.applicationContext)
                .passiveMonitoringClient
                .setPassiveListenerServiceAsync(CaloriesPassiveService::class.java, config)
            registered = true
        } catch (_: Throwable) {
            // Health Services unavailable — the face just shows no burned number.
        }
    }
}

/** Receives the daily calorie total in the background, even with the app closed. */
class CaloriesPassiveService : PassiveListenerService() {
    override fun onNewDataPointsReceived(dataPoints: DataPointContainer) {
        val latest = dataPoints.getData(DataType.CALORIES_DAILY).lastOrNull() ?: return
        val kcal = latest.value.roundToInt()
        if (kcal == CalorieStore.burnedToday(this)) {
            return
        }
        CalorieStore.setBurned(this, kcal)
        CalorieComplicationService.requestUpdate(this, throttle = true)
    }
}

/** Re-registers the calorie listener after the watch restarts. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            HealthLink.ensureRegistered(context)
        }
    }
}
