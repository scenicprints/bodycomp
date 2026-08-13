import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/campaign.dart';
import 'package:bodycomp/food.dart';
import 'package:bodycomp/main.dart';

// 2026-06-01 is a Monday.
final DateTime mon = DateTime(2026, 6, 1);
String d(int offset) => formatDate(mon.add(Duration(days: offset)));

final UserCalibration cal =
    UserCalibration(startWeight: 200, startBf: 0.25, targetBf: 0.15);

DailyLog log(int offset, double w) =>
    DailyLog(date: d(offset), weight: w, bf: 0.25);

FoodEntry food(int offset, double calories, {double protein = 0}) =>
    FoodEntry(
        id: 'f$offset-$calories',
        date: d(offset),
        name: 'test',
        serving: '',
        calories: calories,
        protein: protein,
        fat: 0,
        carbs: 0);

CampaignState run({
  required List<DailyLog> logs,
  List<FoodEntry> foods = const <FoodEntry>[],
  Set<String> fasted = const <String>{},
  int startOffset = 0,
  required int asOfOffset,
}) =>
    CampaignEngine.compute(
        cal: cal,
        logs: logs,
        foods: foods,
        fasted: fasted,
        startDate: d(startOffset),
        asOf: mon.add(Duration(days: asOfOffset)));

void main() {
  group('the roster', () {
    test('60 named enemies, all unique, sizes inside the promised band', () {
      final Set<String> names = <String>{};
      for (int i = 0; i < 60; i++) {
        final EnemyDef e = enemyAt(i);
        names.add(e.name);
        expect(e.sizeMult, greaterThanOrEqualTo(0.75));
        expect(e.sizeMult, lessThanOrEqualTo(3.5));
      }
      expect(names.length, 60);
    });

    test('the road never ends and deeper laps are harder', () {
      expect(enemyAt(60).name, startsWith('Elder '));
      expect(enemyAt(120).name, startsWith('Primal '));
      expect(enemyAt(60).sizeMult, greaterThan(enemyAt(0).sizeMult));
      expect(enemyAt(120).sizeMult, greaterThan(enemyAt(60).sizeMult));
    });

    test('every zone guardian is flagged', () {
      for (int z = 0; z < 6; z++) {
        expect(enemyAt(z * 10 + 9).guardian, true);
        expect(enemyAt(z * 10 + 4).guardian, false);
      }
    });
  });

  group('weekday combat', () {
    test('your damage is TDEE minus intake', () {
      // Mon+Tue logged at 1900, weigh-ins daily; settle through Wednesday.
      final List<DailyLog> logs = <DailyLog>[log(0, 200), log(1, 200), log(2, 200)];
      final List<FoodEntry> foods = <FoodEntry>[food(0, 1900), food(1, 1900)];
      final CampaignState s =
          run(logs: logs, foods: foods, asOfOffset: 2);
      final double tdee =
          MathEngine.tdeeInfo(logs, cal.activityMult).tdee;
      expect(s.totalDamage, closeTo((tdee - 1900) * 2, 0.5));
      expect(s.enemyHp, closeTo(s.enemyMaxHp - s.totalDamage, 0.5));
    });

    test('starving pays no more than the floor', () {
      // A fasted day is a legal FAST — but capped at TDEE−1200.
      final List<DailyLog> logs = <DailyLog>[log(0, 200), log(1, 200)];
      final CampaignState s = run(
          logs: logs, fasted: <String>{d(0)}, asOfOffset: 1);
      final double tdee = MathEngine.tdeeInfo(logs, cal.activityMult).tdee;
      expect(s.totalDamage, closeTo(tdee - 1200, 0.5));
    });

    test('going over maintenance heals the enemy and hurts you', () {
      final List<DailyLog> logs = <DailyLog>[log(0, 200), log(1, 200)];
      final CampaignState s = run(
          logs: logs, foods: <FoodEntry>[food(0, 4000)], asOfOffset: 1);
      expect(s.totalDamage, 0);
      expect(s.totalHealed, greaterThan(0));
      expect(s.playerHp, lessThan(s.playerMaxHp));
      expect(s.enemyHp, s.enemyMaxHp); // healing caps at full
    });

    test('a silent weekday costs 20 HP and deals nothing', () {
      final List<DailyLog> logs = <DailyLog>[log(0, 200)];
      final CampaignState s = run(logs: logs, asOfOffset: 1);
      expect(s.totalDamage, 0);
      expect(s.playerHp, closeTo(s.playerMaxHp - 20, 0.01));
    });

    test('five silent weekdays is a knockout: enemy resets, you respawn', () {
      final List<DailyLog> logs = <DailyLog>[log(0, 200)];
      // Mon..Fri all silent; asOf Saturday.
      final CampaignState s = run(logs: logs, asOfOffset: 5);
      expect(s.koCount, 1);
      expect(s.enemyHp, s.enemyMaxHp);
      expect(s.playerHp, s.playerMaxHp);
    });

    test('a kill spawns the next enemy and pays XP', () {
      // Big clean deficits every weekday for two weeks.
      final List<DailyLog> logs = <DailyLog>[
        for (int i = 0; i <= 12; i++) log(i, 200)
      ];
      final List<FoodEntry> foods = <FoodEntry>[
        for (int i = 0; i <= 11; i++)
          if (mon.add(Duration(days: i)).weekday <= 5) food(i, 1300)
      ];
      final CampaignState s = run(logs: logs, foods: foods, asOfOffset: 12);
      expect(s.kills, isNotEmpty);
      expect(s.enemy.index, s.kills.length);
      expect(s.xp, greaterThanOrEqualTo(50 * s.kills.length));
      expect(s.kills.first.fightDays, greaterThan(0));
    });
  });

  group('weekends', () {
    test('Sat and Sun are free: no silent-day damage', () {
      // Weigh-ins exist; nothing logged Fri(4)→Sun(6). asOf Sunday evening.
      final List<DailyLog> logs = <DailyLog>[log(0, 200), log(5, 200)];
      final List<FoodEntry> foods = <FoodEntry>[
        for (int i = 0; i <= 3; i++) food(i, 1900)
      ];
      final CampaignState s = run(logs: logs, foods: foods, asOfOffset: 6);
      // Only Friday (offset 4) was a silent WEEKDAY.
      expect(s.playerHp, closeTo(s.playerMaxHp - 20, 6.5)); // regen wiggle
      expect(s.weekendMode, true);
    });

    test('boss win: mark Saturday, verdict Monday, under the threshold', () {
      final List<DailyLog> logs = <DailyLog>[
        log(0, 200), log(5, 200), log(7, 200.2)
      ];
      final List<FoodEntry> foods = <FoodEntry>[
        for (int i = 0; i <= 4; i++) food(i, 1900)
      ];
      final CampaignState s = run(logs: logs, foods: foods, asOfOffset: 8);
      expect(s.bossLedger, hasLength(1));
      final BossRecord b = s.bossLedger.single;
      expect(b.result, 'won'); // +0.2 vs 0.35×2 = 0.7 allowed
      expect(b.markWeight, 200);
      expect(b.gain, closeTo(0.2, 1e-9));
      expect(s.xp, greaterThanOrEqualTo(kBossWinXp));
    });

    test('a big weekend gain loses the fight', () {
      final List<DailyLog> logs = <DailyLog>[
        log(0, 200), log(5, 200), log(7, 202.5)
      ];
      final CampaignState s = run(logs: logs, asOfOffset: 8);
      expect(s.bossLedger.single.result, 'lost');
    });

    test('no Monday weigh-in is an automatic loss', () {
      final List<DailyLog> logs = <DailyLog>[log(0, 200), log(5, 200)];
      final CampaignState s = run(logs: logs, asOfOffset: 8);
      expect(s.bossLedger.single.result, 'lost');
      expect(s.bossLedger.single.verdictWeight, isNull);
    });

    test('no weigh-in Thursday through Saturday: the boss passes you by', () {
      final List<DailyLog> logs = <DailyLog>[log(0, 200), log(1, 200)];
      final CampaignState s = run(logs: logs, asOfOffset: 8);
      expect(s.bossLedger.single.result, 'no_mark');
    });

    test('the ratchet: your own unlogged history sets the threshold', () {
      // Three fully-unlogged 2-day gaps gaining 0.2 lb/day feed the average.
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: formatDate(mon.subtract(const Duration(days: 21))), weight: 199, bf: 0.25),
        DailyLog(date: formatDate(mon.subtract(const Duration(days: 19))), weight: 199.4, bf: 0.25),
        DailyLog(date: formatDate(mon.subtract(const Duration(days: 14))), weight: 199.4, bf: 0.25),
        DailyLog(date: formatDate(mon.subtract(const Duration(days: 12))), weight: 199.8, bf: 0.25),
        DailyLog(date: formatDate(mon.subtract(const Duration(days: 7))), weight: 199.8, bf: 0.25),
        DailyLog(date: formatDate(mon.subtract(const Duration(days: 5))), weight: 200.2, bf: 0.25),
        log(5, 200), // Saturday mark
      ];
      // Food on the flat stretches so ONLY the three 2-day jumps qualify
      // as fully-unlogged spans.
      final List<FoodEntry> foods = <FoodEntry>[
        for (int i = -18; i <= -15; i++) food(i, 2000),
        for (int i = -11; i <= -8; i++) food(i, 2000),
        for (int i = -4; i <= 4; i++) food(i, 2000),
      ];
      final CampaignState s = run(logs: logs, foods: foods, asOfOffset: 6);
      expect(s.activeBoss, isNotNull);
      expect(s.activeBoss!.avgGain, closeTo(0.2, 1e-9));
      expect(s.activeBoss!.threshold, closeTo(0.4, 0.01));
    });
  });

  group('today is pending, not settled', () {
    test('logging food today shows a live hit that has not landed', () {
      final List<DailyLog> logs = <DailyLog>[log(0, 200), log(1, 200)];
      final CampaignState s = run(
          logs: logs, foods: <FoodEntry>[food(1, 1500)], asOfOffset: 1);
      expect(s.pendingDamage, isNotNull);
      expect(s.pendingDamage, greaterThan(0));
      expect(s.totalDamage, 0); // yesterday was silent, today not settled
    });

    test('nothing logged today: no pending number to show', () {
      final CampaignState s =
          run(logs: <DailyLog>[log(0, 200)], asOfOffset: 0);
      expect(s.pendingDamage, isNull);
    });
  });

  group('the final boss', () {
    test('HP is the fat between you and the target, in calories', () {
      final List<DailyLog> logs = <DailyLog>[log(0, 200)];
      final CampaignState s = run(logs: logs, asOfOffset: 0);
      // fat 50, lbm 150, target fat at 15% = 150×0.15/0.85 ≈ 26.47
      final double expected = (50 - 150 * 0.15 / 0.85) * 3500;
      expect(s.fatBossHp, closeTo(expected, 1));
      expect(s.fatBossMax, greaterThanOrEqualTo(s.fatBossHp));
    });
  });

  group('determinism', () {
    test('same history in, same battle out', () {
      final List<DailyLog> logs = <DailyLog>[
        for (int i = 0; i <= 12; i++) log(i, 200 - i * 0.1)
      ];
      final List<FoodEntry> foods = <FoodEntry>[
        for (int i = 0; i <= 11; i++) food(i, 1800, protein: 120)
      ];
      final CampaignState a = run(logs: logs, foods: foods, asOfOffset: 12);
      final CampaignState b = run(logs: logs, foods: foods, asOfOffset: 12);
      expect(a.totalDamage, b.totalDamage);
      expect(a.playerHp, b.playerHp);
      expect(a.enemyHp, b.enemyHp);
      expect(a.xp, b.xp);
      expect(a.log.length, b.log.length);
    });
  });

  group('Chad', () {
    test('loses exactly a pound a week from the anchor', () {
      final List<DailyLog> logs = <DailyLog>[
        log(0, 200),
        log(14, 199.5),
      ];
      final RivalState r = RivalEngine.compute(logs,
          campaignStart: d(0), asOf: mon.add(const Duration(days: 14)));
      expect(r.hasData, true);
      expect(r.chadWeight, closeTo(198, 1e-9));
    });

    test('mood tracks the gap', () {
      // You at 200 trend, Chad two weeks in at 198 → he leads by 2 → smug.
      final RivalState smug = RivalEngine.compute(
          <DailyLog>[log(0, 200), log(14, 200)],
          campaignStart: d(0),
          asOf: mon.add(const Duration(days: 14)));
      expect(smug.mood, 1);

      // You dropped 4 lb in two weeks → you passed him → annoyed.
      final RivalState annoyed = RivalEngine.compute(
          <DailyLog>[log(0, 200), log(13, 196.2), log(14, 196)],
          campaignStart: d(0),
          asOf: mon.add(const Duration(days: 14)));
      expect(annoyed.gap, lessThan(0));
      expect(annoyed.mood, 3);
    });

    test('a recalibration after the start re-anchors the race', () {
      final List<DailyLog> logs = <DailyLog>[
        log(0, 200), log(13, 195), log(14, 195),
      ];
      final RivalState r = RivalEngine.compute(logs,
          campaignStart: d(0),
          resetDate: d(14),
          asOf: mon.add(const Duration(days: 14)));
      expect(r.anchorDate, d(14));
      // Chad restarts beside you, not 2 lb ahead.
      expect(r.chadWeight, closeTo(r.anchorWeight, 1e-9));
    });

    test('no data yet: he waits at the start line', () {
      final RivalState r =
          RivalEngine.compute(<DailyLog>[], campaignStart: d(0));
      expect(r.hasData, false);
      expect(r.line, isNotEmpty);
    });

    test('rounds: drop the pound or lose the week', () {
      // Daily weigh-ins, losing 0.2/day (1.4/wk) for 2 weeks, then flat.
      final List<DailyLog> logs = <DailyLog>[
        for (int i = 0; i <= 20; i++)
          log(i, i <= 14 ? 200 - i * 0.2 : 197.2)
      ];
      final List<RivalRound> rounds = RivalEngine.rounds(logs,
          campaignStart: d(0), asOf: mon.add(const Duration(days: 21)));
      expect(rounds, hasLength(3));
      // Week 1 reads short on TREND (the 7-day average lags a standing
      // start — that's the water-weight protection, not a bug). By week 2
      // the lag cancels and the true −1.4/wk pace shows.
      expect(rounds[1].result, 'won');
      expect(rounds[1].delta, closeTo(-1.4, 0.01));
      expect(rounds[2].result, 'lost'); // flat week
    });

    test('a week with no weigh-ins judges nothing', () {
      final List<DailyLog> logs = <DailyLog>[log(0, 200), log(14, 198)];
      final List<RivalRound> rounds = RivalEngine.rounds(logs,
          campaignStart: d(0), asOf: mon.add(const Duration(days: 14)));
      expect(rounds[1].result, 'none'); // days 7..13 empty
    });

    test('a fresh K.O. is gloating material', () {
      final (int _, String line) = RivalEngine.moodLine(
          2.0, DateTime(2026, 6, 15),
          recentKo: true);
      expect(line.toLowerCase(), contains('k'));
      // And the same day without one reads from the normal pool.
      final (int _, String normal) =
          RivalEngine.moodLine(2.0, DateTime(2026, 6, 15));
      expect(normal, isNot(line));
    });

    test('the anchor moves only forward, and only on recalibration', () {
      expect(RivalEngine.anchorFor(d(0), null), d(0));
      expect(RivalEngine.anchorFor(d(0), d(5)), d(5));
      // A reset BEFORE the campaign started cannot drag the race back.
      expect(
          RivalEngine.anchorFor(
              d(0), formatDate(mon.subtract(const Duration(days: 30)))),
          d(0));
    });
  });
}
