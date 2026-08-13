import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/food.dart';

// ═══════════════════════════════════════════════════════════════════════
// Segment-based TDEE engine.
//
// A day of history only counts when the energy balance across it is fully
// known: a weigh-in on each end and calories logged for every day between.
// Everything else is thrown away, never smeared into the estimate.
// ═══════════════════════════════════════════════════════════════════════

String d(int day) => formatDate(DateTime(2026, 1, 1).add(Duration(days: day)));

/// [days] weigh-ins on consecutive dates, weight falling [dropPerDay]/day,
/// [cal] manual calories on every day (0 = weight-only entry).
List<DailyLog> chain(int days,
    {double startW = 200, double dropPerDay = 0.3, int cal = 2000}) {
  return <DailyLog>[
    for (int i = 0; i < days; i++)
      DailyLog(
          date: d(i), weight: startW - i * dropPerDay, bf: 0.25, calories: cal)
  ];
}

void main() {
  group('valid-day accounting', () {
    test('an unbroken daily chain counts every spanned day', () {
      // 15 weigh-ins = 14 spanned days, all with calories.
      final TdeeInfo t = MathEngine.tdeeInfo(chain(15), 1.4);
      expect(t.validDays, 14);
      expect(t.adaptive, isNotNull);
      // (2000 + 0.3 × 3500) = 3050/day before the clamp.
      expect(t.adaptive, closeTo(3050, 1e-6));
    });

    test('a day without calories costs exactly the days it breaks', () {
      final List<DailyLog> logs = chain(15);
      // Day 7 weighed but no calories -> the segment day7->day8 is unknown.
      logs[7] = DailyLog(date: d(7), weight: logs[7].weight, bf: 0.25);
      final TdeeInfo t = MathEngine.tdeeInfo(logs, 1.4);
      expect(t.validDays, 13);
    });

    test('a missing weigh-in does not break a fully-logged span', () {
      // Weigh-ins day 0 and day 3 only, but calories logged on days 0,1,2
      // via the food log -> one valid 3-day segment.
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: d(0), weight: 200, bf: 0.25),
        DailyLog(date: d(3), weight: 199.1, bf: 0.25),
      ];
      final Map<String, double> food = <String, double>{
        d(0): 2000.0,
        d(1): 2000.0,
        d(2): 2000.0,
      };
      final TdeeInfo t = MathEngine.tdeeInfo(logs, 1.4, caloriesByDate: food);
      expect(t.validDays, 3);
    });

    test('an unlogged day inside a span throws the whole segment out', () {
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: d(0), weight: 200, bf: 0.25),
        DailyLog(date: d(3), weight: 199.1, bf: 0.25),
      ];
      final Map<String, double> food = <String, double>{
        d(0): 2000.0,
        // d(1) missing — we genuinely don't know what was eaten.
        d(2): 2000.0,
      };
      final TdeeInfo t = MathEngine.tdeeInfo(logs, 1.4, caloriesByDate: food);
      expect(t.validDays, 0);
      expect(t.adaptive, isNull);
    });

    test('a fasted day is known intake (0 cal); the chain holds', () {
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: d(0), weight: 200, bf: 0.25),
        DailyLog(date: d(2), weight: 199.4, bf: 0.25),
      ];
      final TdeeInfo t = MathEngine.tdeeInfo(logs, 1.4,
          caloriesByDate: <String, double>{d(0): 2000.0},
          fastedDates: <String>{d(1)});
      expect(t.validDays, 2);
    });
  });

  group('trust threshold and fallback', () {
    test('below 10 valid days there is no adaptive number at all', () {
      final TdeeInfo t = MathEngine.tdeeInfo(chain(10), 1.4); // 9 valid days
      expect(t.validDays, 9);
      expect(t.adaptive, isNull);
      expect(t.tdee, closeTo(t.baseline, 1e-9));
    });

    test('at 10 valid days the measured estimate takes over', () {
      final TdeeInfo t = MathEngine.tdeeInfo(chain(11), 1.4);
      expect(t.validDays, 10);
      expect(t.adaptive, isNotNull);
    });

    test('no data at all -> baseline only', () {
      final TdeeInfo t = MathEngine.tdeeInfo(<DailyLog>[], 1.4);
      expect(t.tdee, 0);
      expect(t.adaptive, isNull);
    });
  });

  group('noise immunity', () {
    test('the BF-scale reading cannot move the estimate at all', () {
      // Identical weights/calories, wildly different body-fat readings.
      final List<DailyLog> a = chain(15);
      final List<DailyLog> b = <DailyLog>[
        for (final DailyLog l in a)
          DailyLog(
              date: l.date,
              weight: l.weight,
              bf: 0.10 + (l.date.hashCode % 20) / 100.0,
              calories: l.calories)
      ];
      // Baseline shifts (it rides lean mass), but the MEASURED estimate is
      // weight-only by design — a 1% BF misread is 7000 phantom calories.
      expect(MathEngine.tdeeInfo(b, 1.4).adaptive,
          closeTo(MathEngine.tdeeInfo(a, 1.4).adaptive!, 1e-6));
    });

    test('intermediate water zigzag cancels; only endpoints matter', () {
      final List<DailyLog> smooth = chain(15);
      final List<DailyLog> zigzag = <DailyLog>[
        for (int i = 0; i < smooth.length; i++)
          DailyLog(
              date: smooth[i].date,
              // ±1.5 lb of overnight water on every intermediate day.
              weight: smooth[i].weight +
                  ((i == 0 || i == smooth.length - 1) ? 0 : (i.isEven ? 1.5 : -1.5)),
              bf: 0.25,
              calories: 2000)
      ];
      expect(MathEngine.tdeeInfo(zigzag, 1.4).adaptive,
          closeTo(MathEngine.tdeeInfo(smooth, 1.4).adaptive!, 1e-6));
    });
  });

  group('clamp and reset', () {
    test('an implausible crash clamps to 1.35x baseline', () {
      // 2 lb/day "lost" — mostly water, not 7000 cal/day of burn.
      final TdeeInfo t = MathEngine.tdeeInfo(chain(15, dropPerDay: 2), 1.4);
      expect(t.adaptive, closeTo(9000, 1e-6));
      expect(t.tdee, closeTo(t.baseline * 1.35, 1e-6));
    });

    test('a gaining stretch clamps to 0.75x baseline, never 300', () {
      final TdeeInfo t =
          MathEngine.tdeeInfo(chain(15, dropPerDay: -0.4), 1.4);
      expect(t.tdee, closeTo(t.baseline * 0.75, 1e-6));
      expect(t.tdee, greaterThan(1200));
    });

    test('recalibrating discards everything before the reset date', () {
      final List<DailyLog> logs = chain(15);
      final TdeeInfo t =
          MathEngine.tdeeInfo(logs, 1.4, resetDate: d(10));
      expect(t.validDays, 4); // only day10..day14 survive
      expect(t.adaptive, isNull);
      expect(t.tdee, closeTo(t.baseline, 1e-9));
    });
  });

  group('known intake resolution', () {
    test('food log wins over a legacy manual number', () {
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: d(0), weight: 200, bf: 0.25, calories: 1500),
      ];
      final Map<String, int> known = MathEngine.knownIntakeByDate(
          logs, <String, double>{d(0): 2200.0}, <String>{});
      expect(known[d(0)], 2200);
    });

    test('fasted marks a day 0 even with a manual number absent', () {
      final Map<String, int> known = MathEngine.knownIntakeByDate(
          <DailyLog>[], <String, double>{}, <String>{d(0)});
      expect(known[d(0)], 0);
    });

    test('a bare weigh-in day is simply unknown', () {
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: d(0), weight: 200, bf: 0.25),
      ];
      final Map<String, int> known =
          MathEngine.knownIntakeByDate(logs, <String, double>{}, <String>{});
      expect(known.containsKey(d(0)), false);
    });
  });

  group('macro targets still floor correctly', () {
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

    test('the printed calorie target can never go below the floor', () {
      final UserCalibration cal = UserCalibration(
          startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 99999);
      final MacroTargets t = MacroTargets.compute(
          cal, chain(15, dropPerDay: -0.4), <FoodEntry>[], <String>{});
      expect(t.calories, greaterThanOrEqualTo(1200));
    });
  });
}
