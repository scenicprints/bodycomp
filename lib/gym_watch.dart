import 'dart:async';

import 'gymboard_bridge.dart';
import 'watch_bridge.dart';

// ═══════════════════════════════════════════════════════════════════════
// GYM WATCH LINK — puts the board on your wrist.
//
// The watch app was built to mirror a coached run. A circuit workout is
// the same shape of thing: a phase, a number counting down, and what is
// coming next. So this feeds the existing channel rather than inventing a
// second one, and the Wear app does not change at all.
//
// Two clocks, deliberately. The network poll is slow, because Gymboard's
// session is declarative and says when rest ENDS, never how long is left.
// The push to the wrist is once a second and works the remainder out
// locally, so the countdown is smooth without hammering Firestore.
//
// Read only, like the rest of the Gymboard link. The wrist buttons are
// not wired to the board: the phone and the TV own a session between
// them, and a Pause from a third device would be the first thing in this
// app that writes to Gymboard.
// ═══════════════════════════════════════════════════════════════════════

class GymWatchLink {
  static Timer? _poll;
  static Timer? _push;
  static GymboardSession? _last;
  static bool _onWrist = false;

  static const Duration _liveEvery = Duration(seconds: 5);
  static const Duration _idleEvery = Duration(seconds: 30);

  static bool get running => _poll != null;

  static void start() {
    if (_poll != null) return;
    _schedule(_idleEvery);
    _push = Timer.periodic(const Duration(seconds: 1), (_) => _toWrist());
    _fetch();
  }

  static void stop() {
    _poll?.cancel();
    _poll = null;
    _push?.cancel();
    _push = null;
    if (_onWrist) {
      WatchBridge.end();
      _onWrist = false;
    }
    _last = null;
  }

  static void _schedule(Duration every) {
    _poll?.cancel();
    _poll = Timer.periodic(every, (_) => _fetch());
  }

  static Future<void> _fetch() async {
    final GymboardSession? s = await fetchGymboardSession();
    if (s == null) return; // offline: keep showing the last known state

    final bool wasLive = _last?.live ?? false;
    _last = s;

    // Poll hard only while something is actually happening.
    if (s.live != wasLive) {
      _schedule(s.live ? _liveEvery : _idleEvery);
    }

    if (!s.live && _onWrist) {
      WatchBridge.end();
      _onWrist = false;
    }
  }

  static void _toWrist() {
    final GymboardSession? s = _last;
    if (s == null || !s.live) return;

    final bool resting = s.phase == 'resting';
    WatchBridge.sendState(
      phase: s.watchPhase,
      leftSec: resting ? s.restLeftSec : 0,
      elapsedSec: s.elapsedSec,
      // A circuit is "as fast as you can", not a fixed length, so there is
      // no total to count towards. Sending 0 lets the watch show elapsed
      // without drawing a progress ring against a number nobody set.
      totalSec: 0,
      nextPhase: resting ? 'CIRCUIT ${s.nextCircuit + 1}' : '',
      nextSec: 0,
      level: s.level,
      paused: false,
    );
    _onWrist = true;
  }
}
