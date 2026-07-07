package com.scenicprints.bodycomp.wear

import org.json.JSONObject

// ═══════════════════════════════════════════════════════════════════════
//  The run-state protocol shared with the phone.
//
//  Phone → watch: a JSON blob on path "/bodycomp/run", pushed each second and
//  on every interval change.
//  Watch → phone: a short command string on path "/bodycomp/action"
//  ("toggle" to pause/resume, "stop" to end).
// ═══════════════════════════════════════════════════════════════════════

object RunProtocol {
    const val PATH_STATE = "/bodycomp/run"
    const val PATH_ACTION = "/bodycomp/action"
    const val ACTION_TOGGLE = "toggle"
    const val ACTION_STOP = "stop"
}

/** A snapshot of the coached run as the phone sees it. */
data class RunState(
    val phase: String,     // "WARM UP" | "RUN" | "WALK" | "COOL DOWN"
    val leftSec: Int,      // seconds left in the current interval
    val elapsedSec: Int,   // total elapsed
    val totalSec: Int,     // total workout length
    val nextPhase: String, // "" when none
    val nextSec: Int,
    val level: Int,
    val paused: Boolean,
    val done: Boolean,
) {
    companion object {
        fun parse(json: String): RunState? = try {
            val o = JSONObject(json)
            RunState(
                phase = o.optString("phase", ""),
                leftSec = o.optInt("left", 0),
                elapsedSec = o.optInt("elapsed", 0),
                totalSec = o.optInt("total", 0),
                nextPhase = o.optString("next", ""),
                nextSec = o.optInt("nextSec", 0),
                level = o.optInt("level", 0),
                paused = o.optBoolean("paused", false),
                done = o.optBoolean("done", false),
            )
        } catch (_: Exception) {
            null
        }
    }
}
