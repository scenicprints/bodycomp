import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/grade.dart';

void main() {
  final DateTime now = DateTime(2026, 8, 1);
  final UserCalibration cal = UserCalibration(
      startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 500);

  // Logs from goalStart to `now`, moving `bfDone` of the way to the target.
  List<DailyLog> journey({
    required DateTime start,
    required DateTime upto,
    required double fractionDone,
  }) {
    final int days = upto.difference(start).inDays;
    final List<DailyLog> out = <DailyLog>[];
    for (int i = 0; i <= days; i += 1) {
      final double t = days == 0 ? 1 : i / days;
      final double f = fractionDone * t;
      final double bf = 0.25 - (0.25 - 0.15) * f;
      final double w = 200 - (200 - 176) * f;
      out.add(DailyLog(date: formatDate(start.add(Duration(days: i))),
          weight: w, bf: bf));
    }
    return out;
  }

  group('Navy method', () {
    test('a typical male reading lands in a sane range', () {
      final double? bf =
          navyBodyFat(waistIn: 36, neckIn: 15.5, heightIn: 70);
      expect(bf, isNotNull);
      expect(bf! * 100, greaterThan(15));
      expect(bf * 100, lessThan(30));
    });

    test('a smaller waist gives a lower reading', () {
      final double a = navyBodyFat(waistIn: 38, neckIn: 15.5, heightIn: 70)!;
      final double b = navyBodyFat(waistIn: 34, neckIn: 15.5, heightIn: 70)!;
      expect(b, lessThan(a));
    });

    test('impossible inputs return null instead of NaN', () {
      expect(navyBodyFat(waistIn: 14, neckIn: 15.5, heightIn: 70), isNull);
      expect(navyBodyFat(waistIn: 0, neckIn: 15.5, heightIn: 70), isNull);
      expect(navyBodyFat(waistIn: 36, neckIn: 15.5, heightIn: 0), isNull);
    });

    test('the female formula needs hips and differs from the male one', () {
      expect(
          navyBodyFat(
              waistIn: 32, neckIn: 13, heightIn: 65, female: true),
          isNull); // no hips
      final double? f = navyBodyFat(
          waistIn: 32, neckIn: 13, heightIn: 65, hipIn: 40, female: true);
      expect(f, isNotNull);
      expect(f! * 100, greaterThan(20));
    });
  });

  group('measurement trigger (weight-only, off the lowest weight)', () {
    List<DailyLog> weights(List<double> ws) => <DailyLog>[
          for (int i = 0; i < ws.length; i++)
            DailyLog(
                date: formatDate(now.subtract(Duration(days: ws.length - i))),
                weight: ws[i],
                bf: 0.22)
        ];
    BodyMeasurement at(double w) => BodyMeasurement(
        date: formatDate(now.subtract(const Duration(days: 30))),
        waistIn: 36,
        neckIn: 15.5,
        weightAtMeasure: w,
        bodyFat: 0.22);

    test('asks the very first time', () {
      expect(
          shouldMeasure(
              logs: weights(<double>[200]),
              measurements: <BodyMeasurement>[]),
          true);
    });

    test('does not ask until 4 lb below the last measurement', () {
      expect(
          shouldMeasure(
              logs: weights(<double>[200, 198, 197]),
              measurements: <BodyMeasurement>[at(200)]),
          false);
      expect(
          shouldMeasure(
              logs: weights(<double>[200, 198, 196]),
              measurements: <BodyMeasurement>[at(200)]),
          true);
    });

    test('gaining 5 then losing 4 does NOT re-trigger it', () {
      // Measured at 200. Went up to 205, came back to 201. Lowest is still
      // 200, so nothing new has been achieved.
      expect(
          shouldMeasure(
              logs: weights(<double>[200, 205, 203, 201]),
              measurements: <BodyMeasurement>[at(200)]),
          false);
    });

    test('a genuine new low does trigger it, even in the same week', () {
      expect(
          shouldMeasure(
              logs: weights(<double>[200, 205, 199, 195]),
              measurements: <BodyMeasurement>[at(200)]),
          true);
    });

    test('countdown reports the pounds remaining', () {
      expect(
          lbUntilMeasure(
              logs: weights(<double>[200, 198.5]),
              measurements: <BodyMeasurement>[at(200)]),
          closeTo(2.5, 0.01));
      expect(
          lbUntilMeasure(
              logs: weights(<double>[200, 195]),
              measurements: <BodyMeasurement>[at(200)]),
          0);
    });
  });

  group('reachable deadline', () {
    test('a 500 deficit gives a sane, non-athlete timeline', () {
      final double weeks = weeksToGoal(
          weight: 200, lbm: 150, currentBf: 0.25, targetBf: 0.15, deficit: 500);
      // ~25 lb of fat at ~1 lb/wk, plus buffer — months, not weeks.
      expect(weeks, greaterThan(20));
      expect(weeks, lessThan(60));
    });

    test('an absurd deficit cannot demand an elite pace', () {
      final double sane = weeksToGoal(
          weight: 200, lbm: 150, currentBf: 0.25, targetBf: 0.15, deficit: 500);
      final double crazy = weeksToGoal(
          weight: 200, lbm: 150, currentBf: 0.25, targetBf: 0.15,
          deficit: 5000);
      // Capped at 1% of body weight per week, so it can only be ~2x faster.
      expect(crazy, greaterThan(sane / 2.5));
    });

    test('already at goal needs no time', () {
      expect(
          weeksToGoal(
              weight: 176, lbm: 150, currentBf: 0.14, targetBf: 0.15,
              deficit: 500),
          0);
    });

    test('the deadline is a real future date', () {
      final DateTime d = goalDeadline(
          from: now,
          weight: 200,
          lbm: 150,
          currentBf: 0.25,
          targetBf: 0.15,
          deficit: 500);
      expect(d.isAfter(now), true);
      expect(d.difference(now).inDays, greaterThan(120));
    });
  });

  group('the grade', () {
    test('dead on schedule is an A-', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 100));
      // Halfway through the time, halfway to the goal.
      final List<DailyLog> logs =
          journey(start: start, upto: now, fractionDone: 0.5);
      final GoalGrade g = computeGrade(
          cal: cal, logs: logs, startDate: start, deadline: deadline,
          asOf: now);
      expect(g.gradeable, true);
      expect(g.score, inInclusiveRange(98, 104));
      expect(g.letter, 'A-');
    });

    test('a little ahead is an A; way ahead is an A+', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 100));
      final GoalGrade a = computeGrade(
          cal: cal,
          logs: journey(start: start, upto: now, fractionDone: 0.55),
          startDate: start,
          deadline: deadline,
          asOf: now);
      expect(a.letter, 'A');
      final GoalGrade aPlus = computeGrade(
          cal: cal,
          logs: journey(start: start, upto: now, fractionDone: 0.65),
          startDate: start,
          deadline: deadline,
          asOf: now);
      expect(aPlus.letter, 'A+');
      expect(aPlus.daysEarly, greaterThan(0));
    });

    test('falling behind walks down B, C, D with + and - steps', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 100));
      String at(double done) => computeGrade(
              cal: cal,
              logs: journey(start: start, upto: now, fractionDone: done),
              startDate: start,
              deadline: deadline,
              asOf: now)
          .letter;
      expect(at(0.47), 'B+');
      expect(at(0.44), 'B');
      expect(at(0.41), 'B-');
      expect(at(0.38), 'C+');
      expect(at(0.35), 'C');
      expect(at(0.32), 'C-');
      expect(at(0.28), 'D+');
      expect(at(0.25), 'D');
      expect(at(0.21), 'D-');
      expect(at(0.10), 'F');
    });

    test('every band from the letter table is reachable', () {
      const List<String> want = <String>[
        'A+', 'A', 'A-', 'B+', 'B', 'B-', 'C+', 'C', 'C-', 'D+', 'D', 'D-', 'F'
      ];
      final Set<String> got = <String>{
        for (int s = 0; s <= 200; s++) letterFor(s)
      };
      expect(got, containsAll(want));
    });

    test('behind schedule reports a late arrival date', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 100));
      final GoalGrade g = computeGrade(
          cal: cal,
          logs: journey(start: start, upto: now, fractionDone: 0.25),
          startDate: start,
          deadline: deadline,
          asOf: now);
      expect(g.daysEarly, lessThan(0));
      expect(g.summary, contains('late'));
    });

    test('no deadline or too little data is ungradeable, not an F', () {
      expect(
          computeGrade(
                  cal: cal,
                  logs: <DailyLog>[],
                  startDate: null,
                  deadline: null,
                  asOf: now)
              .gradeable,
          false);
      final DateTime start = now.subtract(const Duration(days: 2));
      expect(
          computeGrade(
                  cal: cal,
                  logs: journey(start: start, upto: now, fractionDone: 0.1),
                  startDate: start,
                  deadline: now.add(const Duration(days: 200)),
                  asOf: now)
              .gradeable,
          false);
    });

    test('the trend arrow compares against a month ago', () {
      final DateTime start = now.subtract(const Duration(days: 100));
      final DateTime deadline = now.add(const Duration(days: 100));
      // Progress accelerating: most of it happened in the last month.
      final List<DailyLog> logs = <DailyLog>[];
      for (int i = 100; i >= 0; i--) {
        final DateTime d = now.subtract(Duration(days: i));
        final double elapsed = (100 - i) / 100;
        final double f = elapsed * elapsed; // slow then fast
        logs.add(DailyLog(
            date: formatDate(d),
            weight: 200 - 24 * f * 0.5,
            bf: 0.25 - 0.10 * f * 0.5));
      }
      final GoalGrade g = gradeWithTrend(
          cal: cal, logs: logs, startDate: start, deadline: deadline,
          asOf: now);
      expect(g.gradeable, true);
      expect(g.deltaScore, isNotNull);
      expect(g.improving, true);
    });
  });

  group('TDEE reset', () {
    test('stale data drives the estimate until you recalibrate', () {
      final List<DailyLog> logs = <DailyLog>[];
      // 20 old days WITH intake logged — these are what the estimate clings to.
      for (int i = 60; i > 40; i--) {
        logs.add(DailyLog(
            date: formatDate(now.subtract(Duration(days: i))),
            weight: 200,
            bf: 0.25,
            calories: 3500));
      }
      // Then 20 recent weigh-ins with NO food logged at all.
      for (int i = 20; i > 0; i--) {
        logs.add(DailyLog(
            date: formatDate(now.subtract(Duration(days: i))),
            weight: 195,
            bf: 0.24));
      }
      final double baseline =
          MathEngine.baselineTdee(MathEngine.rollingLbm(logs), 1.4);

      // Without a reset the old logged days still drive it.
      final double stale = MathEngine.activeTdee(logs, 1.4);
      expect(stale, closeTo(3500, 1));

      // Recalibrating today discards them, so it falls back to the baseline.
      final double afterReset =
          MathEngine.activeTdee(logs, 1.4, resetDate: formatDate(now));
      expect(afterReset, closeTo(baseline, 0.01));
      expect(afterReset, isNot(closeTo(stale, 1)));
    });

    test('a reset with no fresh data falls back to the baseline', () {
      final List<DailyLog> logs = <DailyLog>[
        for (int i = 60; i > 40; i--)
          DailyLog(
              date: formatDate(now.subtract(Duration(days: i))),
              weight: 200,
              bf: 0.25,
              calories: 3500)
      ];
      final double t = MathEngine.activeTdee(logs, 1.4,
          resetDate: formatDate(now));
      final double baseline =
          MathEngine.baselineTdee(MathEngine.rollingLbm(logs), 1.4);
      expect(t, closeTo(baseline, 0.01));
    });
  });
}
