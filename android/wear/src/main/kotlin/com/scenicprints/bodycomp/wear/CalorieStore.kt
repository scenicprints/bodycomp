package com.scenicprints.bodycomp.wear

import android.content.Context
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ═══════════════════════════════════════════════════════════════════════
//  Today's eaten calories for the watch face, kept on the watch. Pushed
//  from the phone's food log (path "/bodycomp/calories").
//
//  The number is stored with the date it belongs to and reads as zero once
//  that date is no longer today, so it resets at local midnight without the
//  phone having to say anything.
//
//  (Burned calories are not stored here: the watch supplies them live to
//  the face. See CalorieComplicationService.)
// ═══════════════════════════════════════════════════════════════════════

object CalorieStore {
    const val PATH_CALORIES = "/bodycomp/calories"

    private const val PREFS = "calories"
    private const val KEY_EATEN = "eaten"
    private const val KEY_EATEN_DATE = "eatenDate"

    /** Local date as 'YYYY-MM-DD' — the same key the phone app uses. */
    fun today(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun setEaten(context: Context, date: String, kcal: Int) {
        prefs(context).edit()
            .putInt(KEY_EATEN, kcal)
            .putString(KEY_EATEN_DATE, date)
            .apply()
    }

    /** Calories eaten today; 0 until the phone reports something for today. */
    fun eatenToday(context: Context): Int {
        val p = prefs(context)
        return if (p.getString(KEY_EATEN_DATE, "") == today()) p.getInt(KEY_EATEN, 0) else 0
    }
}
