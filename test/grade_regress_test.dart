import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/grade.dart';

/// Regressions for two bugs reported from the phone:
///   1. Logging a waist measurement did not clear the "measure your waist"
///      prompt — it kept asking forever.
///   2. Gaining a lot of weight still graded as on track.
void main() {
  final DateTime now = DateTime(2026, 8, 10);
  final UserCalibration cal = UserCalibration(
      startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 500);

  List<DailyLog> logsOf(List<(int, double)> daysAgoAndWeight,
      {double bf = 0.22}) {
    final List<DailyLog> out = <DailyLog>[];
    for (final (int d, double w) in daysAgoAndWeight) {
      out.add(DailyLog(
          date: formatDate(now.subtract(Duration(days: d))),
          weight: w,
          bf: bf));
    }
    out.sort((DailyLog a, DailyLog b) => a.date.compareTo(b.date));
    return out;
  }

  double lowestOf(List<DailyLog> logs) => logs
      .map((DailyLog l) => l.weight)
      .reduce((double a, double b) => a < b ? a : b);

  BodyMeasurement measureNow(List<DailyLog> logs) => BodyMeasurement(
        date: formatDate(now),
        waistIn: 36,
        neckIn: 15.5,
        weightAtMeasure: logs.last.weight,
        lowestAtMeasure: lowestOf(logs),
        bodyFat: 0.22,
      );

  group('bug 1: the prompt must clear once you measure', () {
    test('measuring while ABOVE your all-time low clears the prompt', () {
      // Historic low of 190, currently back up at 200 — the exact situation
      // that made the prompt re-fire immediately after measuring.
      final List<DailyLog> logs = logsOf(<(int, double)>[
        (60, 200),
        (40, 190),
        (5, 198),
        (0, 200),
      ]);
      expect(lowestOf(logs), 190);
      // Before measuring: due (never measured).
      expect(
          shouldMeasure(logs: logs, measurements: <BodyMeasurement>[]), true);
      // After measuring: NOT due any more.
      expect(
          shouldMeasure(
              logs: logs, measurements: <BodyMeasurement>[measureNow(logs)]),
          false);
    });

    test('it stays cleared while you bounce around above the low', () {
      final List<DailyLog> logs = logsOf(<(int, double)>[(40, 190), (0, 200)]);
      final BodyMeasurement m = measureNow(logs);
      final List<DailyLog> later = <DailyLog>[
        ...logs,
        DailyLog(date: formatDate(now.add(const Duration(days: 3))),
            weight: 205, bf: 0.22),
        DailyLog(date: formatDate(now.add(const Duration(days: 9))),
            weight: 194, bf: 0.22),
      ];
      // Lost 11 lb from the peak but never beat the 190 low — no new progress.
      expect(shouldMeasure(logs: later, measurements: <BodyMeasurement>[m]),
          false);
    });

    test('a new all-time low 4 lb under the anchor does re-trigger it', () {
      final List<DailyLog> logs = logsOf(<(int, double)>[(40, 190), (0, 200)]);
      final BodyMeasurement m = measureNow(logs); // anchored to 190
      final List<DailyLog> later = <DailyLog>[
        ...logs,
        DailyLog(date: formatDate(now.add(const Duration(days: 30))),
            weight: 186, bf: 0.21),
      ];
      expect(
          shouldMeasure(logs: later, measurements: <BodyMeasurement>[m]), true);
    });

    test('the countdown reads 4 lb right after measuring', () {
      final List<DailyLog> logs = logsOf(<(int, double)>[(40, 190), (0, 200)]);
      expect(
          lbUntilMeasure(
              logs: logs, measurements: <BodyMeasurement>[measureNow(logs)]),
          4.0);
    });

    test('an old measurement with no anchor still behaves sanely', () {
      // Pre-fix saves have no lowestAtMeasure; they fall back to the weight.
      final List<DailyLog> logs = logsOf(<(int, double)>[(10, 200), (0, 199)]);
      const BodyMeasurement legacy = BodyMeasurement(
          date: '2026-08-01',
          waistIn: 36,
          neckIn: 15.5,
          weightAtMeasure: 200,
          bodyFat: 0.22);
      expect(
          shouldMeasure(logs: logs, measurements: <BodyMeasurement>[legacy]),
          false);
    });
  });

  group('bug 2: gaining weight must not grade as on track', () {
    // Journey started long before the goal date: 200 -> 188 over months, then
    // the goal date is set, then weight climbs back to 196.
    List<DailyLog> gainedSinceGoalDate() {
      final List<DailyLog> out = <DailyLog>[];
      // Old progress, before the deadline existed.
      for (int i = 200; i > 100; i -= 5) {
        final double t = (200 - i) / 100;
        out.add(DailyLog(
            date: formatDate(now.subtract(Duration(days: i))),
            weight: 200 - 12 * t,
            bf: 0.25 - 0.03 * t));
      }
      // Goal date set at day -100 (weight ~188). Then gain back up.
      for (int i = 100; i >= 0; i -= 5) {
        final double t = (100 - i) / 100;
        out.add(DailyLog(
            date: formatDate(now.subtract(Duration(days: i))),
            weight: 188 + 8 * t,
            bf: 0.22 + 0.02 * t));
      }
      return out;
    }

    test('weight up since the goal date grades as failing, not on track', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 200));
      final GoalGrade g = computeGrade(
          cal: cal,
          logs: gainedSinceGoalDate(),
          startDate: start,
          deadline: deadline,
          asOf: now);
      expect(g.gradeable, true);
      expect(g.score, lessThan(40), reason: 'gaining cannot score in the pass range');
      expect(g.letter, 'F');
    });

    test('progress made BEFORE the goal date does not inflate the score', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 200));
      // Flat since the goal date, but 12 lb were lost before it.
      final List<DailyLog> flat = <DailyLog>[];
      for (int i = 200; i > 100; i -= 5) {
        final double t = (200 - i) / 100;
        flat.add(DailyLog(
            date: formatDate(now.subtract(Duration(days: i))),
            weight: 200 - 12 * t,
            bf: 0.25 - 0.03 * t));
      }
      for (int i = 100; i >= 0; i -= 5) {
        flat.add(DailyLog(
            date: formatDate(now.subtract(Duration(days: i))),
            weight: 188,
            bf: 0.22));
      }
      final GoalGrade g = computeGrade(
          cal: cal,
          logs: flat,
          startDate: start,
          deadline: deadline,
          asOf: now);
      // A third of the window gone with zero progress in it.
      expect(g.score, lessThan(40));
    });

    test('real progress since the goal date still grades well', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 100));
      final List<DailyLog> good = <DailyLog>[];
      for (int i = 100; i >= 0; i -= 2) {
        final double t = (100 - i) / 100; // 0 -> 1 across the window
        good.add(DailyLog(
            date: formatDate(now.subtract(Duration(days: i))),
            weight: 200 - 12 * t, // halfway to a 24 lb goal
            bf: 0.25 - 0.05 * t)); // halfway to the bf target
      }
      final GoalGrade g = computeGrade(
          cal: cal,
          logs: good,
          startDate: start,
          deadline: deadline,
          asOf: now);
      expect(g.gradeable, true);
      expect(g.letter, anyOf('A-', 'A', 'A+'));
    });

    test('the summary says late when the pace is short', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 200));
      final GoalGrade g = computeGrade(
          cal: cal,
          logs: gainedSinceGoalDate(),
          startDate: start,
          deadline: deadline,
          asOf: now);
      expect(g.summary.toLowerCase(), contains('no measurable progress'));
    });
  });
}
