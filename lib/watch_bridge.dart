import 'dart:convert';
import 'package:flutter/services.dart';

// ═══════════════════════════════════════════════════════════════════════
// WATCH BRIDGE — the Dart side of the Pixel Watch link.
//
// Pushes the live coached-run state to the Wear OS app and surfaces the
// wrist's Pause/Stop taps as a stream. All calls are best-effort and silent:
// if there's no watch (or the platform side isn't wired), nothing breaks.
// ═══════════════════════════════════════════════════════════════════════

class WatchBridge {
  static const MethodChannel _method = MethodChannel('bodycomp/watch');
  static const EventChannel _events = EventChannel('bodycomp/watch_events');
  static Stream<String>? _actions;

  /// Push the current run snapshot to any connected watch.
  static Future<void> sendState({
    required String phase,
    required int leftSec,
    required int elapsedSec,
    required int totalSec,
    required String nextPhase,
    required int nextSec,
    required int level,
    required bool paused,
  }) async {
    try {
      await _method.invokeMethod<void>(
        'sendState',
        jsonEncode(<String, dynamic>{
          'phase': phase,
          'left': leftSec,
          'elapsed': elapsedSec,
          'total': totalSec,
          'next': nextPhase,
          'nextSec': nextSec,
          'level': level,
          'paused': paused,
          'done': false,
        }),
      );
    } catch (_) {}
  }

  /// Tell the watch the run has ended (it closes the run out).
  static Future<void> end() async {
    try {
      await _method.invokeMethod<void>('end');
    } catch (_) {}
  }

  /// Sync today's eaten calories to the watch, for the calorie-balance watch
  /// face. Sent as a Data Layer *item* (not a message), so it still arrives
  /// if the watch is out of range right now. [date] is 'YYYY-MM-DD'.
  static Future<void> sendCalories({
    required String date,
    required int eaten,
  }) async {
    try {
      await _method.invokeMethod<void>(
        'sendCalories',
        <String, dynamic>{'date': date, 'eaten': eaten},
      );
    } catch (_) {}
  }

  /// 'toggle' (pause/resume) or 'stop', emitted when a wrist button is tapped.
  static Stream<String> actions() {
    _actions ??= _events
        .receiveBroadcastStream()
        .map((dynamic e) => e.toString());
    return _actions!;
  }
}
