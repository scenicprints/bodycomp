import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/food.dart';
import 'package:bodycomp/trainer.dart' show RunRecord;
import 'package:bodycomp/goals.dart';
import 'package:bodycomp/unlocks.dart';

FoodEntry _f(String date, {double protein = 0, double cal = 1500}) => FoodEntry(
    id: '$date-$protein-$cal',
    date: date,
    name: 'meal',
    serving: '1',
    calories: cal,
    protein: protein,
    fat: 40,
    carbs: 120,
    nutrients: const <String, double>{'fiber': 30});

void main() {
  final DateTime now = DateTime(2026, 7, 20, 9);
  final UserCalibration cal = UserCalibration(
      startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 500);

  group('unlock gating', () {
    test('level 1 gets only the classics', () {
      expect(hasUnlock('cel_confetti', 1), true);
      expect(hasUnlock('cel_fireworks', 1), false);
      expect(hasUnlock('f_stats', 1), false);
      expect(unlocksOfKind(UnlockKind.celebration, 1).length, 1);
    });

    test('higher levels open more of each family', () {
      expect(hasUnlock('cel_fireworks', 5), true);
      expect(hasUnlock('f_boss', 5), true);
      expect(hasUnlock('f_monthly', 6), true);
      expect(hasUnlock('f_stats', 9), true);
      expect(hasUnlock('f_titles', 14), true);
      expect(unlocksOfKind(UnlockKind.cardStyle, 12).length, 4);
    });

    test('nextUnlock always points at the nearest locked thing', () {
      final Unlock? n = nextUnlock(1);
      expect(n, isNotNull);
      expect(n!.level, 4); // glass cards
      expect(nextUnlock(1000), isNull);
    });

    test('every unlock id is unique', () {
      final List<String> ids = kUnlocks.map((Unlock u) => u.id).toList();
      expect(ids.length, ids.toSet().length);
    });
  });

  group('insignia + titles', () {
    test('insignia steps with rank', () {
      expect(insigniaFor(1), '🌱');
      expect(insigniaFor(3), '🔰');
      expect(insigniaFor(25), '👑');
    });
    test('titles accumulate, never shrink', () {
      expect(earnedTitles(1), <String>['Rookie']);
      expect(earnedTitles(7).length, 3);
      expect(earnedTitles(25).length, 6);
      expect(earnedTitles(25).last, 'Legend');
    });
  });

  group('knowledge cards', () {
    test('one per level, capped at the library size', () {
      expect(knowledgeFor(0).length, 0);
      expect(knowledgeFor(5).length, 5);
      expect(knowledgeFor(999).length, kKnowledge.length);
    });
    test('all cards have real content', () {
      for (final KnowledgeCard k in kKnowledge) {
        expect(k.title.isNotEmpty, true);
        expect(k.text.length, greaterThan(40));
      }
    });
  });

  group('boss battles', () {
    test('hidden until Boss Battles is unlocked', () {
      final GoalState low = GoalEngine.compute(
          cal, <DailyLog>[], <FoodEntry>[], <String>{}, asOf: now);
      expect(low.level, lessThan(5));
      expect(low.available.any((ChallengeDef d) => isBoss(d.id)), false);
    });

    test('challengeDef finds boss battles too', () {
      expect(challengeDef('boss_protein_30'), isNotNull);
      expect(isBoss('boss_protein_30'), true);
      expect(isBoss('fast_day'), false);
    });

    test('a run-count boss verifies from logged runs', () {
      final String start = formatDate(now.subtract(const Duration(days: 20)));
      final ChallengeRun run = ChallengeRun('boss_run_12', start);
      final MacroTargets t =
          MacroTargets.compute(cal, <DailyLog>[], <FoodEntry>[], <String>{});
      List<RunRecord> runsFrom(int count) => <RunRecord>[
            for (int i = 0; i < count; i++)
              RunRecord(
                  id: 'r$i',
                  date: formatDate(
                      now.subtract(Duration(days: 20 - i))),
                  level: 3,
                  distanceKm: 3,
                  durationSec: 1200)
          ];
      expect(
          GoalEngine.challengeMet(run, t, <FoodEntry>[], <String>{}, now,
              runs: runsFrom(12)),
          true);
      expect(
          GoalEngine.challengeMet(run, t, <FoodEntry>[], <String>{}, now,
              runs: runsFrom(6)),
          false);
    });
  });

  group('prestige / maintenance', () {
    test('round-trips through JSON', () {
      const Prestige p = Prestige(2, '2026-07-01');
      final Prestige back = Prestige.fromJson(p.toJson());
      expect(back.count, 2);
      expect(back.seasonStart, '2026-07-01');
      expect(back.stars, '★★');
      expect(back.active, true);
    });

    test('a prestiged weight lane switches to holding the line', () {
      final List<DailyLog> logs = <DailyLog>[
        for (int i = 6; i >= 0; i--)
          DailyLog(
              date: formatDate(now.subtract(Duration(days: i))),
              weight: 170,
              bf: 0.15)
      ];
      final GoalState normal = GoalEngine.compute(
          cal, logs, <FoodEntry>[], <String>{}, asOf: now);
      final GoalState season = GoalEngine.compute(
          cal, logs, <FoodEntry>[], <String>{},
          prestige: const Prestige(1, '2026-07-01'), asOf: now);
      final Goal nGoal =
          normal.live.firstWhere((Goal g) => g.lane == Lane.weight);
      final Goal sGoal =
          season.live.firstWhere((Goal g) => g.lane == Lane.weight);
      expect(sGoal.id.startsWith('m_'), true);
      expect(sGoal.id, isNot(nGoal.id));
    });
  });

  group('goal insight', () {
    test('every lane returns four filled sections', () {
      final GoalState st = GoalEngine.compute(
          cal,
          <DailyLog>[
            DailyLog(date: formatDate(now), weight: 190, bf: 0.22)
          ],
          <FoodEntry>[_f(formatDate(now), protein: 150)],
          <String>{},
          asOf: now);
      for (final Goal g in st.live) {
        final GoalInsight gi = goalInsight(g, st, deficit: cal.deficit);
        expect(gi.what.isNotEmpty, true, reason: g.id);
        expect(gi.why.isNotEmpty, true, reason: g.id);
        expect(gi.how.isNotEmpty, true, reason: g.id);
        expect(gi.watch.isNotEmpty, true, reason: g.id);
      }
    });

    test('special goals get their own bespoke copy', () {
      final GoalState st = GoalEngine.compute(
          cal,
          <DailyLog>[
            DailyLog(date: formatDate(now), weight: 190, bf: 0.22)
          ],
          <FoodEntry>[],
          <String>{},
          asOf: now);
      final Goal newLow = st.all.firstWhere((Goal g) => g.id == 'w_new_low');
      final Goal generic =
          st.all.firstWhere((Goal g) => g.id.startsWith('w_under_'));
      expect(goalInsight(newLow, st).what,
          isNot(goalInsight(generic, st).what));
      expect(goalInsight(newLow, st).what.toLowerCase(), contains('lower'));
    });

    test('the weight goal quotes a real timeline from the deficit', () {
      final GoalState st = GoalEngine.compute(
          cal,
          <DailyLog>[
            DailyLog(date: formatDate(now), weight: 190, bf: 0.22)
          ],
          <FoodEntry>[],
          <String>{},
          asOf: now);
      final Goal goalW = st.all.firstWhere((Goal g) => g.id == 'w_goal');
      expect(goalInsight(goalW, st, deficit: 500).how, contains('weeks'));
    });
  });
}
