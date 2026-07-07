package com.scenicprints.bodycomp.wear

import android.content.Intent
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService

// ═══════════════════════════════════════════════════════════════════════
//  Receives run-state pushes from the phone even when the watch UI isn't in
//  the foreground. It keeps the LATEST state (so a freshly-opened RunActivity
//  can paint immediately) and, when a run first goes active, best-effort
//  launches the UI so the wrist lights up on its own.
//
//  Note: background activity launch is restricted on modern Android. On Wear
//  OS this often still works for the paired app, but if the OS blocks it the
//  user just opens BodyComp on the watch — the live state is already waiting.
// ═══════════════════════════════════════════════════════════════════════

class PhoneMessageService : WearableListenerService() {

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != RunProtocol.PATH_STATE) {
            return
        }
        val state = RunState.parse(String(event.data, Charsets.UTF_8)) ?: return

        val wasActive = RunStateHolder.latest?.let { !it.done } ?: false
        RunStateHolder.update(state)

        // Only auto-launch on the leading edge of a run (idle/done → active),
        // never every second, and never for the final "done" push.
        if (!state.done && !wasActive) {
            try {
                val intent = Intent(this, RunActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (_: Exception) {
                // Blocked by background-launch policy — the user opens it manually.
            }
        }
    }
}
