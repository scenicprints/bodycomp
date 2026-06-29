import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';

// Builds 14 fully-logged days (weight trending down, calories present).
List<DailyLog> _loggedDays() {
  final List<DailyLog> logs = <DailyLog>[];
  for (int i = 0; i < 14; i++) {
    final double weight = 200.0 - i * 0.3;
    logs.add(DailyLog(
      date: '2026-01-${(i + 1).toString().padLeft(2, '0')}',
      weight: weight,
      bf: 0.25 - i * 0.001,
      calories: 2000,
    ));
  }
  return logs;
}

void main() {
  group('adaptiveTdee ignores weight-only (no-calorie) days', () {
    test('a weight-only entry does not change the adaptive TDEE', () {
      final List<DailyLog> base = _loggedDays();
      final double? before = MathEngine.adaptiveTdee(base);
      expect(before, isNotNull);

      // Log a new day with weight but NO calories (the reported scenario).
      final List<DailyLog> withWeightOnly = <DailyLog>[
        ...base,
        DailyLog(date: '2026-01-15', weight: 195.0, bf: 0.235, calories: 0),
      ];
      final double? after = MathEngine.adaptiveTdee(withWeightOnly);

      expect(after, isNotNull);
      expect(after, closeTo(before!, 1e-9),
          reason: 'TDEE must be unchanged by a weight-only log');
    });

    test('fewer than 14 calorie-logged days -> no adaptive value', () {
      final List<DailyLog> base = _loggedDays();
      // Strip calories from one day -> only 13 logged days remain.
      base[3] = DailyLog(
          date: base[3].date, weight: base[3].weight, bf: base[3].bf);
      expect(MathEngine.adaptiveTdee(base), isNull);
    });

    test('adding calories to that day later resumes counting it', () {
      final List<DailyLog> base = _loggedDays();
      final double? before = MathEngine.adaptiveTdee(base);
      final List<DailyLog> edited = <DailyLog>[
        ...base,
        DailyLog(date: '2026-01-15', weight: 195.0, bf: 0.235, calories: 1600),
      ];
      // Now the new day counts, so the value should move.
      expect(MathEngine.adaptiveTdee(edited), isNot(closeTo(before!, 1e-6)));
    });
  });

  group('baseline TDEE rides smoothed lean mass', () {
    // Below 14 calorie-logged days, activeTdee falls back to the baseline.
    List<DailyLog> _shortRun() {
      final List<DailyLog> logs = <DailyLog>[];
      for (int i = 0; i < 7; i++) {
        logs.add(DailyLog(
            date: '2026-02-${(i + 1).toString().padLeft(2, '0')}',
            weight: 200.0,
            bf: 0.25));
      }
      return logs;
    }

    test('baseline uses 7-day average lean mass, not the latest reading', () {
      final List<DailyLog> logs = _shortRun();
      final double tdee = MathEngine.activeTdee(logs, 1.4);
      final double expected =
          MathEngine.baselineTdee(MathEngine.rollingLbm(logs), 1.4);
      expect(tdee, closeTo(expected, 1e-9));
    });

    test('one noisy weigh-in moves baseline far less than a raw single reading',
        () {
      final List<DailyLog> logs = _shortRun();
      final double before = MathEngine.activeTdee(logs, 1.4);

      // A +5 lb water-weight spike on a single day.
      final List<DailyLog> spiked = <DailyLog>[
        ...logs,
        DailyLog(date: '2026-02-08', weight: 205.0, bf: 0.25),
      ];
      final double smoothed = MathEngine.activeTdee(spiked, 1.4);
      final double rawSingle =
          MathEngine.baselineTdee(spiked.last.lbm, 1.4);

      // Smoothed reacts; raw-single reacts ~8x harder over an 8-day window.
      expect((smoothed - before).abs(), lessThan((rawSingle - before).abs()));
    });
  });
}
