import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// ═══════════════════════════════════════════════════════════════════════
// BOSS ALERTS — the only two notifications the game earns.
//
// The weekend boss mechanically requires an action at a specific moment:
// a Saturday-morning weigh-in sets the mark, and a Monday-morning weigh-in
// is the verdict (missing it is an automatic loss). These are appointment
// reminders, not engagement nags — nothing else in the app notifies.
// ═══════════════════════════════════════════════════════════════════════

class BossAlerts {
  static const int _idMark = 9001;
  static const int _idVerdict = 9002;
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> _init() async {
    if (_ready) {
      return;
    }
    tzdata.initializeTimeZones();
    try {
      final String name = (await FlutterTimezone.getLocalTimezone()).identifier;
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // Falls back to UTC — an hour or two off beats crashing.
    }
    await _plugin.initialize(
        settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    _ready = true;
  }

  /// Next occurrence of [weekday] at [hour]:[minute] local time.
  static tz.TZDateTime _next(int weekday, int hour, int minute) {
    tz.TZDateTime when = tz.TZDateTime.local(
        tz.TZDateTime.now(tz.local).year,
        tz.TZDateTime.now(tz.local).month,
        tz.TZDateTime.now(tz.local).day,
        hour,
        minute);
    while (when.weekday != weekday || when.isBefore(tz.TZDateTime.now(tz.local))) {
      when = when.add(const Duration(days: 1));
    }
    return when;
  }

  /// Schedule (or clear) the two weekly reminders. Safe to call on every
  /// app start — it reschedules idempotently.
  static Future<void> sync({required bool enabled}) async {
    try {
      await _init();
      if (!enabled) {
        await _plugin.cancel(id: _idMark);
        await _plugin.cancel(id: _idVerdict);
        return;
      }
      final AndroidFlutterLocalNotificationsPlugin? android =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      const NotificationDetails details = NotificationDetails(
          android: AndroidNotificationDetails(
        'boss_weekend',
        'Weekend boss',
        channelDescription:
            'Saturday mark and Monday verdict weigh-in reminders',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ));
      await _plugin.zonedSchedule(
        id: _idMark,
        title: 'The boss wants a mark',
        body:
            'Weigh in this morning — the weekend fight starts from that number.',
        scheduledDate: _next(DateTime.saturday, 9, 0),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
      await _plugin.zonedSchedule(
        id: _idVerdict,
        title: 'Verdict morning',
        body:
            'Weigh in now. No Monday weigh-in and the boss wins by forfeit.',
        scheduledDate: _next(DateTime.monday, 7, 30),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    } catch (_) {
      // Notifications are a courtesy — never let them break a launch.
    }
  }
}
