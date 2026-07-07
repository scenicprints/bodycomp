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
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.app.Activity
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable

// ═══════════════════════════════════════════════════════════════════════
//  The watch face for a coached run: big phase label, huge countdown, what's
//  next, and Pause/Stop that talk back to the phone. State arrives from the
//  phone over the Data Layer (via RunStateHolder); button taps go back the
//  same way. The phone stays the single source of truth for the timer.
// ═══════════════════════════════════════════════════════════════════════

class RunActivity : Activity(), MessageClient.OnMessageReceivedListener {

    private lateinit var phaseView: TextView
    private lateinit var countdownView: TextView
    private lateinit var nextView: TextView
    private lateinit var elapsedView: TextView
    private lateinit var pauseBtn: Button
    private lateinit var stopBtn: Button

    private var lastPhase: String? = null
    private val listener: (RunState) -> Unit = { render(it) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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
            pauseBtn.visibility = View.GONE
            stopBtn.text = "Close"
            return
        }

        // Buzz the wrist when the interval flips (RUN ↔ WALK etc.).
        if (lastPhase != null && lastPhase != s.phase) {
            buzz(s.phase == "RUN")
        }
        lastPhase = s.phase

        phaseView.text = if (s.paused) "PAUSED" else s.phase
        phaseView.setTextColor(if (s.paused) Color.GRAY else accent)
        countdownView.text = mmss(s.leftSec)
        nextView.text = if (s.nextPhase.isNotEmpty()) {
            "Next: ${s.nextPhase} ${mmss(s.nextSec)}"
        } else {
            "Final interval"
        }
        elapsedView.text = "${mmss(s.elapsedSec)} / ${mmss(s.totalSec)}"
        pauseBtn.visibility = View.VISIBLE
        pauseBtn.text = if (s.paused) "Resume" else "Pause"
        stopBtn.text = "Stop"
    }

    private fun sendAction(action: String) {
        val ctx = this
        Wearable.getNodeClient(ctx).connectedNodes.addOnSuccessListener { nodes ->
            val client = Wearable.getMessageClient(ctx)
            for (node in nodes) {
                client.sendMessage(
                    node.id,
                    RunProtocol.PATH_ACTION,
                    action.toByteArray(Charsets.UTF_8),
                )
            }
        }
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

    // ── UI built in code (no XML) — a centred column + a button row. ──────
    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0E0F12"))
            setPadding(dp(14), dp(6), dp(14), dp(6))
        }

        phaseView = TextView(this).apply {
            textSize = 20f
            setTypeface(typeface, Typeface.BOLD)
            letterSpacing = 0.15f
            gravity = Gravity.CENTER
            text = "—"
            setTextColor(ACCENT_GREEN)
        }
        countdownView = TextView(this).apply {
            textSize = 52f
            setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL))
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#EEEEEE"))
            text = "--:--"
        }
        nextView = TextView(this).apply {
            textSize = 12f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#888888"))
            text = "Waiting for run…"
        }
        elapsedView = TextView(this).apply {
            textSize = 11f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#666666"))
            text = ""
        }

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, 0)
        }
        pauseBtn = Button(this).apply {
            text = "Pause"
            setOnClickListener { sendAction(RunProtocol.ACTION_TOGGLE) }
        }
        stopBtn = Button(this).apply {
            text = "Stop"
            setOnClickListener {
                val done = RunStateHolder.latest?.done == true
                if (done) finish() else sendAction(RunProtocol.ACTION_STOP)
            }
        }
        buttons.addView(pauseBtn, btnParams())
        buttons.addView(stopBtn, btnParams())

        root.addView(phaseView)
        root.addView(countdownView)
        root.addView(nextView)
        root.addView(elapsedView)
        root.addView(buttons)
        return root
    }

    private fun btnParams() = LinearLayout.LayoutParams(0, dp(40), 1f)
        .apply { setMargins(dp(4), 0, dp(4), 0) }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private val ACCENT_GREEN = Color.parseColor("#4ADE80")
        private val ACCENT_BLUE = Color.parseColor("#5B8DEF")
    }
}
