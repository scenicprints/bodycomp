import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/food.dart';
import 'package:bodycomp/sleep.dart';
import 'package:bodycomp/trainer.dart' show RunRecord;
import 'package:bodycomp/coach.dart';

// Build a run of daily logs ending today, so smoothing windows have data.
List<DailyLog> _logs(DateTime now, int days,
    {required double weight, required double bf, double weightPerDay = 0}) {
  final List<DailyLog> out = <DailyLog>[];
  for (int i = days - 1; i >= 0; i--) {
    final DateTime d = now.subtract(Duration(days: i));
    out.add(DailyLog(
        date: formatDate(d), weight: weight - weightPerDay * i, bf: bf));
  }
  return out;
}

List<FoodEntry> _food(DateTime now, int days,
    {required double protein, required double fiber, double cal = 1800}) {
  final List<FoodEntry> out = <FoodEntry>[];
  for (int i = 0; i < days; i++) {
    out.add(FoodEntry(
        id: 'f$i',
        date: formatDate(now.subtract(Duration(days: i))),
        name: 'meal',
        serving: '1',
        calories: cal,
        protein: protein,
        fat: 60,
        carbs: 150,
        nutrients: <String, double>{'fiber': fiber}));
  }
  return out;
}

void main() {
  final DateTime now = DateTime(2026, 7, 15, 9);
  final UserCalibration cal = UserCalibration(
      startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 500);

  group('AdvisorInsight JSON', () {
    test('round-trips', () {
      final AdvisorInsight i = AdvisorInsight(
          kind: 'weekly',
          periodKey: '2026-06-22',
          text: 'Great week.',
          createdAtMs: 1700000000000);
      final AdvisorInsight back = AdvisorInsight.fromJson(
          jsonDecode(jsonEncode(i.toJson())) as Map<String, dynamic>);
      expect(back.kind, 'weekly');
      expect(back.text, 'Great week.');
      expect(back.createdAtMs, 1700000000000);
    });
  });

  group('daily coach', () {
    test('praises protein when it meets target', () {
      final List<DailyLog> logs =
          _logs(now, 20, weight: 190, bf: 0.22, weightPerDay: 0.1);
      final List<FoodEntry> foods =
          _food(now, 10, protein: 200, fiber: 35);
      final CoachFacts f = CoachFacts.build(cal, logs, foods, <String>{},
          weekly: false, asOf: now);
      final String out = Coach.daily(f);
      expect(out.toLowerCase(), contains('protein'));
      expect(out, contains('✓'));
    });

    test('flags protein + fiber shortfalls', () {
      final List<DailyLog> logs =
          _logs(now, 20, weight: 190, bf: 0.22, weightPerDay: 0.1);
      final List<FoodEntry> foods = _food(now, 10, protein: 60, fiber: 8);
      final CoachFacts f = CoachFacts.build(cal, logs, foods, <String>{},
          weekly: false, asOf: now);
      final String out = Coach.daily(f);
      expect(out, contains('⚠'));
      expect(out.toLowerCase(), contains('fiber'));
    });

    test('never blank; headline present even with almost no data', () {
      final CoachFacts f = CoachFacts.build(
          cal, <DailyLog>[], <FoodEntry>[], <String>{},
          weekly: false, asOf: now);
      expect(Coach.daily(f).trim(), isNotEmpty);
    });

    test('is deterministic — same data, same text', () {
      final List<DailyLog> logs = _logs(now, 20, weight: 190, bf: 0.22);
      final List<FoodEntry> foods = _food(now, 10, protein: 150, fiber: 30);
      final CoachFacts f = CoachFacts.build(cal, logs, foods, <String>{},
          weekly: false, asOf: now);
      expect(Coach.daily(f), Coach.daily(f));
    });
  });

  group('weekly coach', () {
    test('reads recomp when fat falls and lean holds', () {
      // fat mass down (bf falling), lean roughly flat over the month.
      final List<DailyLog> out = <DailyLog>[];
      for (int i = 34; i >= 0; i--) {
        final DateTime d = now.subtract(Duration(days: i));
        final double bf = 0.25 - (34 - i) * 0.0007; // bf slowly down
        out.add(DailyLog(date: formatDate(d), weight: 190, bf: bf));
      }
      final CoachFacts f = CoachFacts.build(
          cal, out, _food(now, 20, protein: 200, fiber: 35), <String>{},
          weekly: true, asOf: now);
      final String s = Coach.weekly(f);
      expect(s.trim(), isNotEmpty);
      expect(s.toLowerCase(), contains('recomp'));
    });
  });

  group('run coach', () {
    RunRecord run({double? avgHr}) => RunRecord(
        id: 'r1',
        date: formatDate(now),
        level: 3,
        distanceKm: 5,
        durationSec: 1800,
        avgHr: avgHr,
        source: 'healthconnect',
        completed: true);

    List<SleepEntry> sleepWith(double resting) => <SleepEntry>[
          for (int i = 0; i < 6; i++)
            SleepEntry(
                id: 's$i',
                date: formatDate(now.subtract(Duration(days: i))),
                asleepMinutes: 450,
                restingHr: resting),
        ];

    test('calls an easy run easy and suggests moving up', () {
      final String s =
          Coach.run(run(avgHr: 110), sleep: sleepWith(55), asOf: now);
      expect(s.toLowerCase(), contains('controlled'));
      expect(s.toLowerCase(), contains('move up'));
    });

    test('calls a grind hard', () {
      final String s =
          Coach.run(run(avgHr: 180), sleep: sleepWith(55), asOf: now);
      expect(s.toLowerCase(), contains('grind'));
    });

    test('handles missing HR without crashing', () {
      final String s = Coach.run(run(), sleep: <SleepEntry>[], asOf: now);
      expect(s.toLowerCase(), contains('no heart-rate'));
    });
  });
}
