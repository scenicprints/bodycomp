import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/food.dart';
import 'package:bodycomp/sleep.dart';
import 'package:bodycomp/goals.dart';

SleepEntry night(String date, double hours) => SleepEntry(
    id: 'sl_$date',
    date: date,
    asleepMinutes: (hours * 60).round(),
    restingHr: 55);

void main() {
  final DateTime now = DateTime(2026, 8, 4, 9);
  final UserCalibration cal = UserCalibration(
      startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 500);
  final List<DailyLog> logs = <DailyLog>[
    for (int i = 6; i >= 0; i--)
      DailyLog(
          date: formatDate(now.subtract(Duration(days: i))),
          weight: 195,
          bf: 0.24)
  ];

  Goal sleepGoal(List<SleepEntry> sleep, String id) => GoalEngine.compute(
        cal,
        logs,
        <FoodEntry>[],
        <String>{},
        sleep: sleep,
        asOf: now,
      ).all.firstWhere((Goal g) => g.id == id);

  group('a 7.9-hour night counts', () {
    test('Well Rested is satisfied by one 7.9h night', () {
      final Goal g =
          sleepGoal(<SleepEntry>[night(formatDate(now), 7.9)], 's_first');
      expect(g.done, true, reason: '7.9 h is comfortably over 7 h');
      expect(g.desc, '1/1');
    });

    test('Recharged counts it as 1 of 3, not 0', () {
      final Goal g =
          sleepGoal(<SleepEntry>[night(formatDate(now), 7.9)], 's_three');
      expect(g.desc, '1/3');
      expect(g.progress, closeTo(1 / 3, 0.001));
    });

    test('three consecutive 7h+ nights complete Recharged', () {
      final List<SleepEntry> s = <SleepEntry>[
        night(formatDate(now.subtract(const Duration(days: 2))), 7.2),
        night(formatDate(now.subtract(const Duration(days: 1))), 7.9),
        night(formatDate(now), 7.1),
      ];
      expect(sleepGoal(s, 's_three').done, true);
    });

    test('a gap resets the consecutive run but not the bank', () {
      final List<SleepEntry> s = <SleepEntry>[
        night(formatDate(now.subtract(const Duration(days: 4))), 7.5),
        night(formatDate(now.subtract(const Duration(days: 3))), 7.5),
        // missed night
        night(formatDate(now.subtract(const Duration(days: 1))), 7.5),
        night(formatDate(now), 7.9),
      ];
      expect(sleepGoal(s, 's_three').desc, '2/3'); // run restarted
      expect(sleepGoal(s, 's_seven').desc, '4/7'); // bank keeps all four
    });

    test('a short night does not count', () {
      expect(sleepGoal(<SleepEntry>[night(formatDate(now), 6.4)], 's_first').done,
          false);
    });
  });

  group('definitive requirements', () {
    test('every live goal states exactly what it takes, with numbers', () {
      final GoalState st = GoalEngine.compute(
        cal,
        logs,
        <FoodEntry>[],
        <String>{},
        sleep: <SleepEntry>[night(formatDate(now), 7.9)],
        asOf: now,
      );
      for (final Goal g in st.live) {
        expect(g.requirement.isNotEmpty, true, reason: g.id);
        // "You are at X of Y" or an explicit amount to move.
        expect(
            g.requirement.contains(' of ') ||
                g.requirement.contains('lb') ||
                g.requirement.contains('%') ||
                g.requirement.contains('km'),
            true,
            reason: '${g.id}: ${g.requirement}');
      }
    });

    test('Recharged spells out the consecutive rule and the count', () {
      final Goal g =
          sleepGoal(<SleepEntry>[night(formatDate(now), 7.9)], 's_three');
      expect(g.requirement.toUpperCase(), contains('BACK TO BACK'));
      expect(g.requirement, contains('7+ hours'));
      expect(g.requirement, contains('1 of 3'));
    });

    test('the weight checkpoint quotes the exact pounds to lose', () {
      final GoalState st = GoalEngine.compute(
          cal, logs, <FoodEntry>[], <String>{}, asOf: now);
      final Goal w = st.live.firstWhere((Goal g) => g.lane == Lane.weight);
      expect(w.requirement, contains('lb'));
      expect(w.requirement, contains('to lose'));
    });

    test('nutrition names the actual gram target', () {
      final GoalState st = GoalEngine.compute(
          cal, logs, <FoodEntry>[], <String>{}, asOf: now);
      final Goal n = st.live.firstWhere((Goal g) => g.lane == Lane.nutrition);
      expect(n.requirement, contains(' g'));
      expect(n.requirement, contains('days'));
    });
  });
}
