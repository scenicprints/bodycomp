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
// foreground service simply keeps alive. Its one active job is to relay
// notification button taps (Pause/Resume, Stop) — which arrive here, in the
// service isolate — back to the UI isolate that owns the run.
class _RunTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    // The UI isolate listens via FlutterForegroundTask.addTaskDataCallback.
    FlutterForegroundTask.sendDataToMain(id);
  }
}

// Button ids relayed from the notification to the run screen.
const String kRunActionToggle = 'toggle'; // Pause ⇄ Resume
const String kRunActionStop = 'stop'; // end the run

class RunService {
  static bool _configured = false;

  static void _configure() {
    if (_configured) {
      return;
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // NOTE: a channel's importance is fixed when it is first created and
        // can't be raised later — so bumping the id ('_v2') forces Android to
        // recreate it at DEFAULT, which is what makes it show on the lock
        // screen (the old LOW channel was hidden there). onlyAlertOnce +
        // no sound/vibration keep the per-second updates silent.
        channelId: 'run_service_v2',
        channelName: 'Run in progress',
        channelDescription: 'Keeps your run timing while the screen is off.',
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
        playSound: false,
        enableVibration: false,
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
        notificationButtons: _buttons(false),
        callback: runServiceCallback,
      );
    } catch (_) {}
  }

  // Pause/Resume + Stop, tappable from the lock screen and mirrored to a
  // Pixel Watch. The first button's label tracks the run's paused state.
  static List<NotificationButton> _buttons(bool paused) => <NotificationButton>[
        NotificationButton(
            id: kRunActionToggle, text: paused ? 'Resume' : 'Pause'),
        const NotificationButton(id: kRunActionStop, text: 'Stop'),
      ];

  /// Push the current run state into the ongoing notification so the lock
  /// screen (and the mirrored watch card) show the live interval + countdown.
  /// Cheap and safe to call every second — the channel is onlyAlertOnce, so
  /// updates never re-buzz. No-op if the service isn't running.
  static Future<void> update({
    required String title,
    required String text,
    required bool paused,
  }) async {
    try {
      if (!await FlutterForegroundTask.isRunningService) {
        return;
      }
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
        notificationButtons: _buttons(paused),
      );
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
