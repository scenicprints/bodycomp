import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/food.dart';
import 'package:bodycomp/progress.dart';

FoodEntry _f(String date, {double protein = 0, double fiber = 0, double cal = 1500}) =>
    FoodEntry(
        id: '$date-$protein',
        date: date,
        name: 'meal',
        serving: '1',
        calories: cal,
        protein: protein,
        fat: 40,
        carbs: 120,
        nutrients: <String, double>{'fiber': fiber});

void main() {
  final DateTime now = DateTime(2026, 7, 20, 9);
  final UserCalibration cal = UserCalibration(
      startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 500);

  group('level curve', () {
    test('thresholds and inversion line up', () {
      expect(xpToReach(1), 0);
      expect(xpToReach(2), 100);
      expect(xpToReach(3), 300);
      expect(levelForXp(0), 1);
      expect(levelForXp(99), 1);
      expect(levelForXp(100), 2);
      expect(levelForXp(299), 2);
      expect(levelForXp(300), 3);
    });
  });

  group('XP + achievements', () {
    test('losing fat awards big XP and unlocks fat badges', () {
      // start fat mass = 50 lb; drop to 40 lb → 10 lb fat lost.
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: formatDate(now), weight: 180, bf: 40 / 180),
      ];
      final GameStats s =
          GameStats.compute(cal, logs, <FoodEntry>[], <String>{}, asOf: now);
      expect(s.fatLostLb, closeTo(10, 0.2));
      expect(s.xp, greaterThanOrEqualTo(10 * kXpPerFatLb));
      final Map<String, bool> byId = <String, bool>{
        for (final Achievement a in s.achievements) a.id: a.unlocked
      };
      expect(byId['fat_5'], true);
      expect(byId['fat_10'], true);
      expect(byId['fat_20'], false);
    });

    test('empty history is level 1, nothing unlocked but first_log locked', () {
      final GameStats s = GameStats.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{}, asOf: now);
      expect(s.level, 1);
      expect(s.xp, 0);
      expect(s.unlockedCount, 0);
    });

    test('deterministic', () {
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: formatDate(now), weight: 190, bf: 0.22),
      ];
      final List<FoodEntry> foods = <FoodEntry>[_f(formatDate(now), protein: 180, fiber: 35)];
      final GameStats a = GameStats.compute(cal, logs, foods, <String>{}, asOf: now);
      final GameStats b = GameStats.compute(cal, logs, foods, <String>{}, asOf: now);
      expect(a.xp, b.xp);
      expect(a.currentStreak, b.currentStreak);
    });
  });

  group('forgiving streak', () {
    // Protein target here is lbm*1.0 ≈ 190*0.78 ≈ 148 g; 200 g clears 90%.
    List<FoodEntry> proteinDays(List<int> daysAgo) => <FoodEntry>[
          for (final int d in daysAgo)
            _f(formatDate(now.subtract(Duration(days: d))), protein: 200, fiber: 30)
        ];
    List<DailyLog> weightDays(List<int> daysAgo) => <DailyLog>[
          for (final int d in daysAgo)
            DailyLog(date: formatDate(now.subtract(Duration(days: d))), weight: 190, bf: 0.22)
        ];

    test('one missed day does not break the streak', () {
      // hit 0,1,2, miss 3, hit 4,5 → forgiving streak spans all → 5 qualifying.
      final List<int> hit = <int>[0, 1, 2, 4, 5];
      final GameStats s = GameStats.compute(
          cal, weightDays(<int>[0, 1, 2, 3, 4, 5]), proteinDays(hit), <String>{},
          asOf: now);
      expect(s.currentStreak, 5);
      expect(s.bestStreak, greaterThanOrEqualTo(5));
    });

    test('two misses in a row break it', () {
      // hit 0,1, miss 2,3, hit 4,5,6 → current chain (today side) = 2.
      final GameStats s = GameStats.compute(
          cal,
          weightDays(<int>[0, 1, 2, 3, 4, 5, 6]),
          proteinDays(<int>[0, 1, 4, 5, 6]),
          <String>{},
          asOf: now);
      expect(s.currentStreak, 2);
      expect(s.bestStreak, 3); // the 4,5,6 chain
    });

    test('no qualifying days = zero streak', () {
      final GameStats s = GameStats.compute(
          cal, weightDays(<int>[0, 1, 2]),
          proteinDays(<int>[]), <String>{}, asOf: now);
      expect(s.currentStreak, 0);
      expect(s.bestStreak, 0);
    });
  });
}
