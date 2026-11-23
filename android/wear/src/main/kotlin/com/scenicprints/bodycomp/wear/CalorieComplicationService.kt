package com.scenicprints.bodycomp.wear

import android.content.ComponentName
import android.content.Context
import android.os.SystemClock
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.RangedValueComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import java.util.Locale

// ═══════════════════════════════════════════════════════════════════════
//  Feeds the BodyComp watch face (android/watchface). A Watch Face Format
//  face cannot read calories or do maths across two sources, so this hands
//  it one ready-made RANGED_VALUE complication:
//
//    value  eaten − burned, shifted by +GAP_OFFSET so it is never negative
//           (the face subtracts the offset again); clamped to ±GAP_LIMIT
//    text   eaten today, formatted            e.g. "1,480"
//    title  burned today, formatted, or "–"   e.g. "1,790"
//
//  GAP_OFFSET / GAP_LIMIT must match android/watchface/tools/gen_watchface.py.
// ═══════════════════════════════════════════════════════════════════════

class CalorieComplicationService : ComplicationDataSourceService() {

    override fun onComplicationRequest(
        request: ComplicationRequest,
        listener: ComplicationDataSourceService.ComplicationRequestListener,
    ) {
        // Cheap no-op once registered; covers a process that was just restarted.
        HealthLink.ensureRegistered(this)
        listener.onComplicationData(
            build(CalorieStore.eatenToday(this), CalorieStore.burnedToday(this)),
        )
    }

    override fun getPreviewData(type: ComplicationType): ComplicationData? =
        if (type == ComplicationType.RANGED_VALUE) build(1480, 1790) else null

    private fun build(eaten: Int, burned: Int?): ComplicationData {
        // Without a burned number there is no meaningful gap: show a centred bar.
        val gap = if (burned == null) 0 else (eaten - burned).coerceIn(-GAP_LIMIT, GAP_LIMIT)
        val eatenText = fmt(eaten)
        val burnedText = if (burned == null) "–" else fmt(burned)
        return RangedValueComplicationData.Builder(
            (gap + GAP_OFFSET).toFloat(),
            0f,
            (2 * GAP_OFFSET).toFloat(),
            PlainComplicationText.Builder("$eatenText eaten, $burnedText burned").build(),
        )
            .setText(PlainComplicationText.Builder(eatenText).build())
            .setTitle(PlainComplicationText.Builder(burnedText).build())
            .build()
    }

    private fun fmt(n: Int): String = String.format(Locale.getDefault(), "%,d", n)

    companion object {
        const val GAP_OFFSET = 5000
        const val GAP_LIMIT = 5000

        private const val MIN_GAP_MS = 30_000L

        @Volatile
        private var lastRequestMs = 0L

        /**
         * Ask the system to re-read the complication now. Burned calories tick
         * up constantly, so those pushes are throttled; an eaten change is not.
         */
        fun requestUpdate(context: Context, throttle: Boolean) {
            val now = SystemClock.elapsedRealtime()
            if (throttle && now - lastRequestMs < MIN_GAP_MS) {
                return
            }
            lastRequestMs = now
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
