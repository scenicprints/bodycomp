package com.scenicprints.bodycomp.wear

import android.Manifest
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import java.util.Locale

// ═══════════════════════════════════════════════════════════════════════
//  The whole watch app, as far as the wrist can see: one quiet status
//  screen. Its real job is to ask, once, for the activity permission — the
//  watch only gives the "calories burned today" number to the BodyComp
//  watch face if this app holds it. After that there is nothing to do here.
//
//  (This app used to mirror the coached run. That feature is gone.)
// ═══════════════════════════════════════════════════════════════════════

class MainActivity : ComponentActivity() {

    private lateinit var statusView: TextView

    private val activityPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                // The face can now be given the live burned number.
                CalorieComplicationService.requestUpdate(this)
            }
            render()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())
        if (!CalorieComplicationService.hasActivityPermission(this)) {
            activityPermission.launch(Manifest.permission.ACTIVITY_RECOGNITION)
        }
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        statusView.text = if (CalorieComplicationService.hasActivityPermission(this)) {
            val eaten = String.format(Locale.getDefault(), "%,d", CalorieStore.eatenToday(this))
            "Watch face is set up.\n$eaten kcal eaten today."
        } else {
            "Tap to allow activity access, so the watch face can show calories burned."
        }
    }

    private fun buildUi(): LinearLayout {
        val title = TextView(this).apply {
            text = "BodyComp"
            textSize = 18f
            setTextColor(WATERMELON)
            gravity = Gravity.CENTER
        }
        statusView = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.rgb(0xB4, 0xB2, 0xA9))
            gravity = Gravity.CENTER
            setPadding(0, 12, 0, 0)
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.BLACK)
            setPadding(48, 48, 48, 48)
            addView(title)
            addView(statusView)
            // If the first prompt was dismissed, a tap asks again.
            setOnClickListener {
                if (!CalorieComplicationService.hasActivityPermission(this@MainActivity)) {
                    activityPermission.launch(Manifest.permission.ACTIVITY_RECOGNITION)
                }
            }
        }
    }

    private companion object {
        val WATERMELON = Color.rgb(0xF5, 0x56, 0x6E)
    }
}
