package com.scenicprints.bodycomp.wear

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import androidx.wear.protolayout.expression.DynamicBuilders.DynamicFloat
import androidx.wear.protolayout.expression.DynamicBuilders.DynamicInt32
import androidx.wear.protolayout.expression.PlatformHealthSources
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.DynamicComplicationText
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.RangedValueComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import androidx.wear.watchface.complications.datasource.ComplicationDataTimeline
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.TimeInterval
import androidx.wear.watchface.complications.datasource.TimelineEntry
import java.time.Duration
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

// ═══════════════════════════════════════════════════════════════════════
//  Feeds the BodyComp watch face (android/watchface). A Watch Face Format
//  face cannot read calories or do maths across two sources, so this hands
//  it one ready-made RANGED_VALUE complication:
//
//    value  eaten − burned, shifted by +GAP_OFFSET so it is never negative
//           (the face subtracts the offset again)
//    text   eaten today, formatted            e.g. "1,480"
//    title  burned today, formatted, or "–"   e.g. "1,790"
//
//  "Burned" is NOT read by this app. It is a dynamic value
//  (PlatformHealthSources.dailyCalories) that the watch itself evaluates,
//  and only while the face is awake and on screen. So the numbers are live
//  the moment the watch wakes, and nothing runs for them while it sleeps —
//  no background listener, no polling. The watch only lets an app use that
//  value if it holds ACTIVITY_RECOGNITION, which MainActivity asks for.
//
//  This service is asked for fresh data only when the eaten number changes
//  (a push from the phone), plus a slow safety-net period set in the
//  manifest. Midnight is handled by a timeline entry, not by waking up.
//
//  GAP_OFFSET must match android/watchface/tools/gen_watchface.py.
// ═══════════════════════════════════════════════════════════════════════

class CalorieComplicationService : ComplicationDataSourceService() {

    override fun onComplicationRequest(
        request: ComplicationRequest,
        listener: ComplicationDataSourceService.ComplicationRequestListener,
    ) {
        val today = build(CalorieStore.eatenToday(this))
        try {
            // From local midnight the eaten number is zero again, without
            // anyone having to ask this service a second time.
            val midnight = LocalDate.now().plusDays(1)
                .atStartOfDay(ZoneId.systemDefault()).toInstant()
            listener.onComplicationDataTimeline(
                ComplicationDataTimeline(
                    today,
                    listOf(
                        TimelineEntry(
                            TimeInterval(midnight, midnight.plus(Duration.ofDays(1))),
                            build(0),
                        ),
                    ),
                ),
            )
        } catch (_: Throwable) {
            listener.onComplicationData(today)
        }
    }

    override fun getPreviewData(type: ComplicationType): ComplicationData? =
        if (type == ComplicationType.RANGED_VALUE) preview() else null

    /** Live data: burned is evaluated by the watch whenever the face is awake. */
    private fun build(eaten: Int): ComplicationData {
        val eatenText = fmt(eaten)
        val burned = PlatformHealthSources.dailyCalories()
        val gap = DynamicFloat.constant((eaten + GAP_OFFSET).toFloat()).minus(burned)
        val burnedText = burned.asInt().format(
            DynamicInt32.IntFormatter.Builder().setGroupingUsed(true).build(),
        )
        return RangedValueComplicationData.Builder(
            gap,
            // Shown if the watch cannot evaluate the value (no permission
            // yet, for instance): a centred, empty bar.
            GAP_OFFSET.toFloat(),
            0f,
            (2 * GAP_OFFSET).toFloat(),
            PlainComplicationText.Builder("Calories eaten and burned today").build(),
        )
            .setText(PlainComplicationText.Builder(eatenText).build())
            .setTitle(DynamicComplicationText(burnedText, "–"))
            .build()
    }

    /** Fixed sample numbers for the face picker. */
    private fun preview(): ComplicationData =
        RangedValueComplicationData.Builder(
            (1480 - 1790 + GAP_OFFSET).toFloat(),
            0f,
            (2 * GAP_OFFSET).toFloat(),
            PlainComplicationText.Builder("Calories eaten and burned today").build(),
        )
            .setText(PlainComplicationText.Builder(fmt(1480)).build())
            .setTitle(PlainComplicationText.Builder(fmt(1790)).build())
            .build()

    private fun fmt(n: Int): String = String.format(Locale.getDefault(), "%,d", n)

    companion object {
        const val GAP_OFFSET = 5000

        fun hasActivityPermission(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) ==
                PackageManager.PERMISSION_GRANTED

        /** Ask the system to re-read the complication now (the eaten number changed). */
        fun requestUpdate(context: Context) {
            try {
                ComplicationDataSourceUpdateRequester.create(
                    context.applicationContext,
                    ComponentName(context, CalorieComplicationService::class.java),
                ).requestUpdateAll()
            } catch (_: Throwable) {
            }
        }
    }
}
