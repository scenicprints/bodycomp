import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/food.dart';
import 'package:bodycomp/trainer.dart' show RunRecord;
import 'package:bodycomp/goals.dart';

FoodEntry _f(String date,
        {double protein = 0, double fiber = 0, double sugars = 0, double cal = 1500}) =>
    FoodEntry(
        id: '$date-$protein-$cal',
        date: date,
        name: 'meal',
        serving: '1',
        calories: cal,
        protein: protein,
        fat: 40,
        carbs: 120,
        nutrients: <String, double>{'fiber': fiber, 'sugars': sugars});

void main() {
  final DateTime now = DateTime(2026, 7, 20, 9);
  final UserCalibration cal = UserCalibration(
      startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 500);

  List<DailyLog> logsFor(List<double> weights, {double bf = 0.22}) {
    final List<DailyLog> out = <DailyLog>[];
    for (int i = 0; i < weights.length; i++) {
      out.add(DailyLog(
          date: formatDate(now.subtract(Duration(days: weights.length - 1 - i))),
          weight: weights[i],
          bf: bf));
    }
    return out;
  }

  group('levels', () {
    test('curve and inversion agree', () {
      expect(xpToReach(1), 0);
      expect(xpToReach(2), 100);
      expect(levelForXp(0), 1);
      expect(levelForXp(100), 2);
      expect(levelForXp(299), 2);
      expect(levelForXp(300), 3);
    });
    test('ranks climb', () {
      expect(rankName(1), 'Rookie');
      expect(rankName(3), 'Rising');
      expect(rankName(25), 'Legend');
    });
  });

  group('lanes always produce a live goal', () {
    test('six lanes even with zero data', () {
      final GoalState s = GoalEngine.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{}, asOf: now);
      expect(s.live.length, 6);
      for (final Goal g in s.live) {
        expect(g.title.isNotEmpty, true);
      }
      expect(s.level, 1);
    });

    test('one live goal per lane, in lane order', () {
      final GoalState s = GoalEngine.compute(
          cal, logsFor(<double>[198, 196, 194]), <FoodEntry>[], <String>{},
          asOf: now);
      expect(s.live.map((Goal g) => g.lane).toList(),
          <Lane>[Lane.weight, Lane.body, Lane.running, Lane.nutrition, Lane.consistency, Lane.sleep]);
    });
  });

  group('weight ladder', () {
    test('generates descending checkpoints and completes passed ones', () {
      // start 200, now 188 → "under 195" and "under 190" are cleared.
      final GoalState s = GoalEngine.compute(
          cal, logsFor(<double>[200, 195, 190, 188]), <FoodEntry>[], <String>{},
          asOf: now);
      final Set<String> doneIds = s.completed.map((Goal g) => g.id).toSet();
      expect(doneIds.contains('w_under_195'), true);
      expect(doneIds.contains('w_under_190'), true);
      final Goal live = s.live.firstWhere((Goal g) => g.lane == Lane.weight);
      expect(live.title, 'Get under 185');
      expect(live.desc, contains('to go'));
    });

    test('New Low tallies every time a low is beaten', () {
      final GoalState s = GoalEngine.compute(
          cal, logsFor(<double>[200, 199, 198, 197]), <FoodEntry>[], <String>{},
          asOf: now);
      // Find the repeatable in completed-or-live.
      final Goal low = s.all.firstWhere((Goal g) => g.id == 'w_new_low');
      expect(low.timesDone, 3);
      // A repeatable never "completes" but still earns and shows on the shelf.
      expect(s.tallied.any((Goal g) => g.id == 'w_new_low'), true);
      expect(s.xp, greaterThanOrEqualTo(3 * kXpSmall));
    });

    test('XP accrues as goals complete', () {
      final GoalState none = GoalEngine.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{}, asOf: now);
      final GoalState some = GoalEngine.compute(
          cal, logsFor(<double>[200, 190, 185]), <FoodEntry>[], <String>{},
          asOf: now);
      expect(some.xp, greaterThan(none.xp));
    });
  });

  group('journey bar', () {
    test('0% at start, grows toward the goal weight', () {
      final GoalState s0 = GoalEngine.compute(
          cal, logsFor(<double>[200]), <FoodEntry>[], <String>{}, asOf: now);
      final GoalState s1 = GoalEngine.compute(
          cal, logsFor(<double>[200, 185]), <FoodEntry>[], <String>{}, asOf: now);
      expect(s0.journey, closeTo(0, 0.02));
      expect(s1.journey, greaterThan(s0.journey));
      expect(s1.journey, lessThanOrEqualTo(1.0));
    });
  });

  group('forgiving streak + freezes', () {
    List<FoodEntry> proteinOn(List<int> daysAgo) => <FoodEntry>[
          for (final int d in daysAgo)
            _f(formatDate(now.subtract(Duration(days: d))),
                protein: 200, fiber: 35)
        ];
    List<DailyLog> weightOn(List<int> daysAgo) => <DailyLog>[
          for (final int d in daysAgo)
            DailyLog(
                date: formatDate(now.subtract(Duration(days: d))),
                weight: 190,
                bf: 0.22)
        ];

    test('a single missed day does not break it', () {
      final GoalState s = GoalEngine.compute(
          cal,
          weightOn(<int>[0, 1, 2, 3, 4, 5]),
          proteinOn(<int>[0, 1, 2, 4, 5]),
          <String>{},
          asOf: now);
      expect(s.currentStreak, 5);
    });

    test('a two-day gap is covered when a freeze is banked', () {
      // Enough cleared goals to be past level 3 → at least one freeze.
      final GoalState s = GoalEngine.compute(
          cal,
          weightOn(<int>[0, 1, 2, 3, 4, 5, 6]),
          proteinOn(<int>[0, 1, 4, 5, 6]),
          <String>{},
          asOf: now);
      expect(s.freezeCapacity, greaterThan(0));
      expect(s.freezesUsed, 1);
      expect(s.currentStreak, 5); // the chain survived the gap
    });

    test('a three-day gap breaks it regardless of freezes', () {
      final GoalState s = GoalEngine.compute(
          cal,
          weightOn(<int>[0, 1, 2, 3, 4, 5, 6, 7]),
          proteinOn(<int>[0, 1, 5, 6, 7]),
          <String>{},
          asOf: now);
      expect(s.currentStreak, 2);
      expect(s.bestStreak, 3);
    });

    test('freeze capacity grows with level', () {
      final GoalState s = GoalEngine.compute(
          cal, logsFor(<double>[200, 190, 185, 180]), <FoodEntry>[], <String>{},
          asOf: now);
      expect(s.freezeCapacity, s.level ~/ 3);
    });
  });

  group('challenges', () {
    test('locked ones stay hidden until the level is reached', () {
      final GoalState s = GoalEngine.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{}, asOf: now);
      expect(s.level, 1);
      final Set<String> ids = s.available.map((ChallengeDef d) => d.id).toSet();
      expect(ids.contains('fast_day'), true); // unlock 1
      expect(ids.contains('dry_week'), false); // unlock 6
    });

    test('a fasted day auto-completes Fast Day', () {
      final String today = formatDate(now);
      final ChallengeRun run = ChallengeRun('fast_day', today);
      final MacroTargets t = MacroTargets.compute(
          cal, logsFor(<double>[190]), <FoodEntry>[], <String>{});
      expect(
          GoalEngine.challengeMet(
              run, t, <FoodEntry>[], <String>{today}, now),
          true);
      expect(GoalEngine.challengeMet(run, t, <FoodEntry>[], <String>{}, now),
          false);
    });

    test('sugar detox needs three clean days', () {
      final ChallengeRun run =
          ChallengeRun('sugar_detox', formatDate(now.subtract(const Duration(days: 2))));
      final List<DailyLog> logs = logsFor(<double>[190]);
      final MacroTargets t =
          MacroTargets.compute(cal, logs, <FoodEntry>[], <String>{});
      final List<FoodEntry> clean = <FoodEntry>[
        for (int i = 2; i >= 0; i--)
          _f(formatDate(now.subtract(Duration(days: i))), protein: 150, sugars: 10)
      ];
      expect(GoalEngine.challengeMet(run, t, clean, <String>{}, now), true);
      final List<FoodEntry> sweet = <FoodEntry>[
        for (int i = 2; i >= 0; i--)
          _f(formatDate(now.subtract(Duration(days: i))), protein: 150, sugars: 60)
      ];
      expect(GoalEngine.challengeMet(run, t, sweet, <String>{}, now), false);
    });

    test('finished challenges pay XP', () {
      final String today = formatDate(now);
      final GoalState s = GoalEngine.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{},
          challenges: <ChallengeRun>[ChallengeRun('fast_day', today, today)],
          asOf: now);
      expect(s.xp, greaterThanOrEqualTo(kXpMed));
      expect(s.finishedChallenges.length, 1);
    });
  });

  group('running lane', () {
    RunRecord run(int daysAgo, {double km = 3, int sec = 1200}) => RunRecord(
        id: 'r$daysAgo',
        date: formatDate(now.subtract(Duration(days: daysAgo))),
        level: 3,
        distanceKm: km,
        durationSec: sec);

    test('first run clears Lace Up and moves the lane on', () {
      final GoalState s = GoalEngine.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{},
          runs: <RunRecord>[run(0)], asOf: now);
      expect(s.completed.any((Goal g) => g.id == 'r_lace_up'), true);
      final Goal live = s.live.firstWhere((Goal g) => g.lane == Lane.running);
      expect(live.id, isNot('r_lace_up'));
    });

    test('distance milestones accumulate', () {
      final GoalState s = GoalEngine.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{},
          runs: <RunRecord>[
            for (int i = 0; i < 4; i++) run(i, km: 3)
          ],
          asOf: now);
      expect(s.completed.any((Goal g) => g.id == 'r_10km'), true);
      expect(s.completed.any((Goal g) => g.id == 'r_25km'), false);
    });
  });

  group('skins', () {
    test('auto is always available; others gate by level', () {
      final GoalState s = GoalEngine.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{}, asOf: now);
      expect(s.unlockedThemes.first.id, 'auto');
      expect(s.unlockedThemes.length, 1);
      expect(skinArgb('auto'), 0);
      expect(skinArgb('gold'), isNot(0));
    });
    test('trims step bronze → silver → gold', () {
      expect(trimFor(0), '');
      expect(trimFor(2), 'bronze');
      expect(trimFor(6), 'silver');
      expect(trimFor(12), 'gold');
    });
  });

  test('deterministic', () {
    final List<DailyLog> logs = logsFor(<double>[200, 195, 192]);
    final List<FoodEntry> foods = <FoodEntry>[_f(formatDate(now), protein: 180)];
    final GoalState a =
        GoalEngine.compute(cal, logs, foods, <String>{}, asOf: now);
    final GoalState b =
        GoalEngine.compute(cal, logs, foods, <String>{}, asOf: now);
    expect(a.xp, b.xp);
    expect(a.live.map((Goal g) => g.id).toList(),
        b.live.map((Goal g) => g.id).toList());
  });
}
