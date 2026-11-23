package com.scenicprints.bodycomp.wear

import android.content.Context
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ═══════════════════════════════════════════════════════════════════════
//  Today's two calorie numbers for the watch face, kept on the watch.
//
//  eaten  — pushed from the phone's food log (path "/bodycomp/calories").
//  burned — the watch's own daily calorie count, from Health Services.
//
//  Each number is stored with the date it belongs to and reads as "nothing
//  yet" once that date is no longer today, so both reset at local midnight
//  without the phone having to say anything.
// ═══════════════════════════════════════════════════════════════════════

object CalorieStore {
    const val PATH_CALORIES = "/bodycomp/calories"

    private const val PREFS = "calories"
    private const val KEY_EATEN = "eaten"
    private const val KEY_EATEN_DATE = "eatenDate"
    private const val KEY_BURNED = "burned"
    private const val KEY_BURNED_DATE = "burnedDate"

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

    fun setBurned(context: Context, kcal: Int) {
        prefs(context).edit()
            .putInt(KEY_BURNED, kcal)
            .putString(KEY_BURNED_DATE, today())
            .apply()
    }

    /** Calories eaten today; 0 until the phone reports something for today. */
    fun eatenToday(context: Context): Int {
        val p = prefs(context)
        return if (p.getString(KEY_EATEN_DATE, "") == today()) p.getInt(KEY_EATEN, 0) else 0
    }

    /** Calories burned today, or null if the watch has not reported yet today. */
    fun burnedToday(context: Context): Int? {
        val p = prefs(context)
        return if (p.getString(KEY_BURNED_DATE, "") == today()) p.getInt(KEY_BURNED, 0) else null
    }
}
