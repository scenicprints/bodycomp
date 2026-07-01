import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/trainer.dart';

void main() {
  group('Run ladder', () {
    test('climbs from short intervals to a 30-min continuous run', () {
      expect(kRunLadder.first.longestRun, 60);
      expect(kRunLadder.last.longestRun, 1800);
      expect(kMaxLevel, kRunLadder.length);
      // Monotonic by the longest continuous run — the real progression signal
      // (moving to continuous running deliberately lowers total interval volume).
      for (int i = 1; i < kRunLadder.length; i++) {
        expect(kRunLadder[i].longestRun,
            greaterThanOrEqualTo(kRunLadder[i - 1].longestRun));
      }
    });

    test('every workout is bracketed by a warmup and cooldown walk', () {
      for (final Workout w in kRunLadder) {
        expect(w.intervals.first.kind, IntervalKind.warmup);
        expect(w.intervals.last.kind, IntervalKind.cooldown);
      }
    });

    test('no trailing walk before the cooldown', () {
      final Workout w = workoutForLevel(1);
      // …run, walk, run (last), cooldown — the interval before cooldown is a run.
      final RunInterval beforeCooldown =
          w.intervals[w.intervals.length - 2];
      expect(beforeCooldown.kind, IntervalKind.run);
    });

    test('workoutForLevel clamps out-of-range levels', () {
      expect(workoutForLevel(0).level, 1);
      expect(workoutForLevel(999).level, kMaxLevel);
    });
  });

  group('Calibration', () {
    test('non-runner starts at the bottom', () {
      expect(startingLevel(0), 1);
    });
    test('a 10-minute runner starts mid-ladder', () {
      expect(startingLevel(10), 7);
    });
    test('a strong base starts near the top', () {
      expect(startingLevel(40), kMaxLevel);
    });
  });

  group('Adaptive leveling from HR vs resting', () {
    test('a controlled run (HR near resting) advances one rung', () {
      // resting 55, run 120 → reserve 65 (≤70) → advance
      expect(assessLevel(3, avgHr: 120, restingHr: 55), 4);
    });

    test('a grind (HR far above resting) drops one rung', () {
      // resting 55, run 170 → reserve 115 (≥110) → drop
      expect(assessLevel(3, avgHr: 170, restingHr: 55), 2);
    });

    test('a solid run in between holds', () {
      // resting 55, run 145 → reserve 90 → hold
      expect(assessLevel(3, avgHr: 145, restingHr: 55), 3);
    });

    test('no heart rate or no resting baseline never moves the level', () {
      expect(assessLevel(3, avgHr: null, restingHr: 55), 3);
      expect(assessLevel(3, avgHr: 120, restingHr: null), 3);
    });

    test('never climbs past the top or below 1', () {
      expect(assessLevel(kMaxLevel, avgHr: 100, restingHr: 55), kMaxLevel);
      expect(assessLevel(1, avgHr: 175, restingHr: 55), 1);
    });
  });

  group('Heart-rate effort', () {
    test('classifies easy / ok / hard by %max HR (age 30 → max 190)', () {
      expect(effortFromHr(120, 30), Effort.easy); // 63%
      expect(effortFromHr(150, 30), Effort.ok); // 79%
      expect(effortFromHr(175, 30), Effort.hard); // 92%
    });
  });

  group('RunRecord', () {
    test('computes pace and a readable label', () {
      const RunRecord r = RunRecord(
          id: 'a',
          date: '2026-06-30',
          level: 5,
          distanceKm: 5,
          durationSec: 1800);
      expect(r.paceSecPerKm, 360);
      expect(r.paceLabel, '6:00 /km');
    });

    test('handles a distance-less run', () {
      const RunRecord r = RunRecord(
          id: 'a', date: '2026-06-30', level: 0, distanceKm: 0, durationSec: 600);
      expect(r.paceLabel, '—');
    });

    test('round-trips through JSON', () {
      const RunRecord r = RunRecord(
          id: 'a',
          date: '2026-06-30',
          level: 5,
          distanceKm: 5,
          durationSec: 1800,
          avgHr: 150,
          source: 'healthconnect',
          completed: true,
          effort: 'ok');
      final RunRecord back = RunRecord.fromJson(r.toJson());
      expect(back.distanceKm, 5);
      expect(back.avgHr, 150);
      expect(back.source, 'healthconnect');
    });
  });

  group('Deficit-aware load', () {
    test('counts only runs within the trailing 7 days', () {
      final List<RunRecord> runs = <RunRecord>[
        const RunRecord(
            id: '1', date: '2026-06-28', level: 1, distanceKm: 2, durationSec: 600),
        const RunRecord(
            id: '2', date: '2026-06-25', level: 1, distanceKm: 2, durationSec: 600),
        const RunRecord(
            id: '3', date: '2026-06-01', level: 1, distanceKm: 2, durationSec: 600),
      ];
      expect(runsThisWeek(runs, DateTime.parse('2026-06-30')), 2);
    });

    test('flags high run volume against a steep deficit', () {
      expect(fuelingFlag(3, 700), isNotNull);
      expect(fuelingFlag(1, 700), isNull); // low volume
      expect(fuelingFlag(4, 300), isNull); // shallow deficit
    });
  });
}
