package com.scenicprints.bodycomp.wear

import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.wear.ambient.AmbientLifecycleObserver
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable

// ═══════════════════════════════════════════════════════════════════════
//  The watch face for a coached run: a glanceable, read-only mirror of the
//  phone — big phase label, huge countdown, what's next, and total progress —
//  plus a wrist buzz at each interval switch. Controls stay on the phone; the
//  watch just shows what's happening. State arrives over the Data Layer via
//  RunStateHolder.
// ═══════════════════════════════════════════════════════════════════════

class RunActivity : ComponentActivity(), MessageClient.OnMessageReceivedListener {

    private lateinit var phaseView: TextView
    private lateinit var countdownView: TextView
    private lateinit var nextView: TextView
    private lateinit var elapsedView: TextView

    private var lastPhase: String? = null
    private var ambient = false
    private val listener: (RunState) -> Unit = { render(it) }

    // Always-on: keeps the run displayed (dimmed) when the wrist drops, instead
    // of the watch returning to its face and burying the app.
    private val ambientObserver by lazy {
        AmbientLifecycleObserver(
            this,
            object : AmbientLifecycleObserver.AmbientLifecycleCallback {
                override fun onEnterAmbient(
                    details: AmbientLifecycleObserver.AmbientDetails
                ) {
                    ambient = true
                    RunStateHolder.latest?.let { render(it) }
                }

                override fun onExitAmbient() {
                    ambient = false
                    RunStateHolder.latest?.let { render(it) }
                }

                override fun onUpdateAmbient() {
                    RunStateHolder.latest?.let { render(it) }
                }
            },
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Enabling ambient must never crash the run screen if the wearable
        // library is somehow unavailable.
        try {
            lifecycle.addObserver(ambientObserver)
        } catch (_: Throwable) {
        }
        setContentView(buildUi())
        RunStateHolder.latest?.let { render(it) }
    }

    override fun onResume() {
        super.onResume()
        RunStateHolder.addListener(listener)
        Wearable.getMessageClient(this).addListener(this)
        RunStateHolder.latest?.let { render(it) }
    }

    override fun onPause() {
        super.onPause()
        RunStateHolder.removeListener(listener)
        Wearable.getMessageClient(this).removeListener(this)
    }

    // Low-latency path: the activity also listens directly, funnelling into the
    // same holder the background service feeds.
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path == RunProtocol.PATH_STATE) {
            RunState.parse(String(event.data, Charsets.UTF_8))?.let {
                RunStateHolder.update(it)
            }
        }
    }

    private fun render(s: RunState) {
        val accent = phaseColor(s.phase)
        if (s.done) {
            phaseView.text = "DONE"
            phaseView.setTextColor(ACCENT_GREEN)
            countdownView.text = "✓"
            nextView.text = "Run complete"
            elapsedView.text = mmss(s.elapsedSec)
            return
        }

        // Buzz the wrist when the interval flips (RUN ↔ WALK etc.).
        if (lastPhase != null && lastPhase != s.phase) {
            buzz(s.phase == "RUN")
        }
        lastPhase = s.phase

        phaseView.text = if (s.paused) "PAUSED" else s.phase
        // In ambient (always-on) mode, drop the bright accent for a muted grey
        // so the display is low-power and burn-in-friendly.
        phaseView.setTextColor(
            when {
                s.paused -> Color.GRAY
                ambient -> Color.parseColor("#B0B0B0")
                else -> accent
            }
        )
        countdownView.text = mmss(s.leftSec)
        nextView.text = if (s.nextPhase.isNotEmpty()) {
            "Next: ${s.nextPhase} ${mmss(s.nextSec)}"
        } else {
            "Final interval"
        }
        elapsedView.text = "${mmss(s.elapsedSec)} / ${mmss(s.totalSec)}"
    }

    private fun buzz(strong: Boolean) {
        val vib = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE)
                    as? android.os.VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as? Vibrator
        } ?: return
        val ms = if (strong) 500L else 250L
        vib.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
    }

    private fun phaseColor(phase: String): Int = when (phase) {
        "RUN" -> ACCENT_GREEN
        "WALK" -> ACCENT_BLUE
        else -> Color.parseColor("#AAAAAA")
    }

    private fun mmss(sec: Int): String {
        val s = if (sec < 0) 0 else sec
        return "%02d:%02d".format(s / 60, s % 60)
    }

    // ── UI built in code (no XML) — a single centred column, no controls. ──
    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0E0F12"))
            setPadding(dp(14), dp(6), dp(14), dp(6))
        }

        phaseView = TextView(this).apply {
            textSize = 22f
            setTypeface(typeface, Typeface.BOLD)
            letterSpacing = 0.15f
            gravity = Gravity.CENTER
            text = "—"
            setTextColor(ACCENT_GREEN)
        }
        countdownView = TextView(this).apply {
            textSize = 58f
            setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL))
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#EEEEEE"))
            text = "--:--"
        }
        nextView = TextView(this).apply {
            textSize = 13f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#888888"))
            text = "Waiting for run…"
        }
        elapsedView = TextView(this).apply {
            textSize = 12f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#666666"))
            text = ""
        }

        root.addView(phaseView)
        root.addView(countdownView)
        root.addView(nextView)
        root.addView(elapsedView)
        return root
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private val ACCENT_GREEN = Color.parseColor("#4ADE80")
        private val ACCENT_BLUE = Color.parseColor("#5B8DEF")
    }
}
