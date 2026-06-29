import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/food.dart';

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

  group('fasting vs. didn\'t-log', () {
    String pad(int i) => i.toString().padLeft(2, '0');

    test('a fasted day is counted (0 cal); an unlogged day is not', () {
      final List<DailyLog> logs = <DailyLog>[];
      for (int i = 0; i < 13; i++) {
        logs.add(DailyLog(
            date: '2026-03-${pad(i + 1)}', weight: 200 - i * 0.2, bf: 0.25));
      }
      logs.add(DailyLog(date: '2026-03-14', weight: 197, bf: 0.24)); // bare day
      final Map<String, double> byDate = <String, double>{
        for (int i = 0; i < 13; i++) '2026-03-${pad(i + 1)}': 2000
      };

      // Unlogged bare day → excluded (13 known days).
      expect(MathEngine.resolveIntake(logs, byDate, <String>{}).length, 13);

      // Marked fasted → included as a real 0-cal day (14 known days).
      final List<DailyLog> withFast =
          MathEngine.resolveIntake(logs, byDate, <String>{'2026-03-14'});
      expect(withFast.length, 14);
      expect(withFast.last.calories, 0);
    });
  });

  group('macro targets', () {
    test('derive from body composition; overrides win', () {
      final UserCalibration cal =
          UserCalibration(startWeight: 200, startBf: 0.25, targetBf: 0.15);
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: '2026-03-01', weight: 200, bf: 0.25) // lbm = 150
      ];
      final MacroTargets t =
          MacroTargets.compute(cal, logs, <FoodEntry>[], <String>{});
      expect(t.protein, closeTo(150, 1e-6)); // 1 g / lb lean mass
      expect(t.fat, closeTo(60, 1e-6)); // 0.3 g / lb body weight

      final MacroTargets t2 = MacroTargets.compute(
          cal.copyWith(proteinTarget: 180), logs, <FoodEntry>[], <String>{});
      expect(t2.protein, 180);
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
