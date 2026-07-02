import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/insights.dart';
import 'package:bodycomp/sleep.dart';
import 'package:bodycomp/trainer.dart';

SleepEntry _night(String date, double hours,
        {double? restingHr, double? hrv, int? deep, int? rem, int? light}) =>
    SleepEntry(
      id: date,
      date: date,
      asleepMinutes: (hours * 60).round(),
      restingHr: restingHr,
      hrv: hrv,
      deepMin: deep,
      remMin: rem,
      lightMin: light,
    );

RunRecord _run(String date, int level, double km, int sec,
        {double? avgHr, bool completed = true, String id = ''}) =>
    RunRecord(
      id: id.isEmpty ? 'r_$date' : id,
      date: date,
      level: level,
      distanceKm: km,
      durationSec: sec,
      avgHr: avgHr,
      completed: completed,
    );

void main() {
  group('trendOf', () {
    test('needs at least 4 points', () {
      expect(trendOf(<double>[1, 2, 3]), isNull);
      expect(trendOf(<double>[1, 2, 3, 4]), isNotNull);
    });

    test('reports a falling series as a negative delta', () {
      final SeriesTrend? t = trendOf(<double>[60, 58, 54, 50, 48, 46]);
      expect(t, isNotNull);
      expect(t!.delta, lessThan(0));
      expect(t.rising, isFalse);
    });

    test('reports a rising series as a positive delta', () {
      final SeriesTrend? t = trendOf(<double>[40, 42, 45, 48, 50, 52]);
      expect(t!.delta, greaterThan(0));
      expect(t.rising, isTrue);
    });

    test('ignores non-finite values', () {
      final SeriesTrend? t =
          trendOf(<double>[10, double.nan, 12, 14, 16, 18]);
      expect(t, isNotNull);
      expect(t!.n, 5);
    });
  });

  group('sleepNightRead', () {
    // A fortnight of steady 7h nights with resting HR ~52.
    List<SleepEntry> steady() {
      final List<SleepEntry> out = <SleepEntry>[];
      for (int i = 1; i <= 14; i++) {
        out.add(_night('2026-06-${i.toString().padLeft(2, '0')}', 7.0,
            restingHr: 52, hrv: 60));
      }
      return out;
    }

    test('flags a short night below the personal norm', () {
      final List<SleepEntry> all = steady()
        ..add(_night('2026-06-15', 5.0, restingHr: 52, hrv: 60));
      final InsightRead r = sleepNightRead(all.last, all);
      expect(r.headline, anyOf('Short night', 'Below your norm'));
      expect(r.notes.any((String n) => n.contains('below your')), isTrue);
    });

    test('elevated resting HR reads as run down', () {
      final List<SleepEntry> all = steady()
        ..add(_night('2026-06-15', 7.0, restingHr: 60, hrv: 60));
      final InsightRead r = sleepNightRead(all.last, all);
      expect(r.headline, 'You may be run down');
      expect(r.notes.any((String n) => n.contains('above')), isTrue);
    });

    test('a strong, well-recovered night reads positively', () {
      final List<SleepEntry> all = steady()
        ..add(_night('2026-06-15', 8.5, restingHr: 49, hrv: 70));
      final InsightRead r = sleepNightRead(all.last, all);
      expect(r.headline, 'A strong night');
    });

    test('never throws with no baseline (single night)', () {
      final SleepEntry only = _night('2026-06-15', 7.0);
      expect(() => sleepNightRead(only, <SleepEntry>[only]), returnsNormally);
    });
  });

  group('run insights', () {
    test('avgPaceSecPerKmAtLevel excludes the run itself', () {
      final List<RunRecord> runs = <RunRecord>[
        _run('2026-06-01', 5, 3.0, 1200, id: 'a'), // 400 s/km
        _run('2026-06-08', 5, 3.0, 1080, id: 'b'), // 360 s/km
        _run('2026-06-15', 5, 3.0, 900, id: 'c'), // 300 s/km
      ];
      // Average of a & b, excluding c.
      expect(avgPaceSecPerKmAtLevel(runs, 5, exceptId: 'c'), closeTo(380, 0.01));
      expect(avgPaceSecPerKmAtLevel(runs, 7), isNull);
    });

    test('a faster-than-average run notes the improvement', () {
      final List<RunRecord> runs = <RunRecord>[
        _run('2026-06-01', 5, 3.0, 1200, avgHr: 150, id: 'a'),
        _run('2026-06-08', 5, 3.0, 1200, avgHr: 150, id: 'b'),
        _run('2026-06-15', 5, 3.0, 900, avgHr: 150, id: 'c'), // much faster
      ];
      final InsightRead r =
          runRead(runs.last, runs, restingHr: 55);
      expect(r.headline, 'Fastest at Level 5');
      expect(r.notes.any((String n) => n.contains('faster')), isTrue);
    });

    test('effort is judged from HR reserve over resting', () {
      final RunRecord grind = _run('2026-06-15', 5, 3.0, 1000, avgHr: 180);
      final InsightRead r = runRead(grind, <RunRecord>[grind], restingHr: 55);
      expect(r.notes.any((String n) => n.contains('grind')), isTrue);
      expect(r.headline, 'A hard grind');
    });

    test('a partial run reads as partial', () {
      final RunRecord partial =
          _run('2026-06-15', 5, 1.0, 300, completed: false);
      expect(runRead(partial, <RunRecord>[partial]).headline, 'Partial run');
    });
  });
}
