import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// ═══════════════════════════════════════════════════════════════════════
// RUN SERVICE — an Android foreground service that keeps a guided run alive
// while the phone is locked in a pocket, so the interval timer keeps ticking
// and the run/walk cues fire on time (the OS otherwise suspends the app and
// the timer stops). Started when a coached run begins, stopped when it ends.
// ═══════════════════════════════════════════════════════════════════════

@pragma('vm:entry-point')
void runServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_RunTaskHandler());
}

// Minimal handler — the actual timer runs in the UI isolate, which the
// foreground service simply keeps alive.
class _RunTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class RunService {
  static bool _configured = false;

  static void _configure() {
    if (_configured) {
      return;
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'run_service',
        channelName: 'Run in progress',
        channelDescription: 'Keeps your run timing while the screen is off.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _configured = true;
  }

  /// Start the run-keep-alive service (idempotent).
  static Future<void> start() async {
    try {
      _configure();
      if (await FlutterForegroundTask.isRunningService) {
        return;
      }
      final NotificationPermission p =
          await FlutterForegroundTask.checkNotificationPermission();
      if (p != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      await FlutterForegroundTask.startService(
        serviceId: 512,
        notificationTitle: 'Run in progress',
        notificationText: 'Timing your intervals — tap to return.',
        callback: runServiceCallback,
      );
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
