package com.scenicprints.bodycomp.wear

import android.os.Handler
import android.os.Looper

// ═══════════════════════════════════════════════════════════════════════
//  A tiny in-process bus for the latest run state. Both the message service
//  (background) and the activity (foreground) receive Data Layer messages;
//  they funnel through here so whichever is alive has the newest snapshot and
//  the open UI is nudged to repaint on the main thread.
// ═══════════════════════════════════════════════════════════════════════

object RunStateHolder {
    @Volatile
    var latest: RunState? = null
        private set

    private val listeners = mutableSetOf<(RunState) -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    fun update(state: RunState) {
        latest = state
        val snapshot: List<(RunState) -> Unit>
        synchronized(listeners) { snapshot = listeners.toList() }
        main.post { snapshot.forEach { it(state) } }
    }

    fun addListener(l: (RunState) -> Unit) {
        synchronized(listeners) { listeners.add(l) }
    }

    fun removeListener(l: (RunState) -> Unit) {
        synchronized(listeners) { listeners.remove(l) }
    }
}
