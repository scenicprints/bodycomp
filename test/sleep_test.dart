import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/sleep.dart';

SleepEntry _e(String date, double hours, {int? deep, int? rem}) => SleepEntry(
      id: date,
      date: date,
      asleepMinutes: (hours * 60).round(),
      deepMin: deep,
      remMin: rem,
    );

void main() {
  final DateTime today = DateTime.parse('2026-06-30');

  group('SleepMath', () {
    test('latest picks the most recent night', () {
      final List<SleepEntry> e = <SleepEntry>[
        _e('2026-06-28', 7),
        _e('2026-06-29', 6),
        _e('2026-06-27', 8),
      ];
      expect(SleepMath.latest(e)!.date, '2026-06-29');
      expect(SleepMath.latest(<SleepEntry>[]), isNull);
    });

    test('averageHours covers only the trailing window', () {
      final List<SleepEntry> e = <SleepEntry>[
        _e('2026-06-29', 6),
        _e('2026-06-28', 8),
        _e('2026-06-01', 4), // outside the 7-day window
      ];
      expect(SleepMath.averageHours(e, today, 7), 7.0);
      expect(SleepMath.averageHours(<SleepEntry>[], today, 7), isNull);
    });

    test('baseline needs at least 3 nights', () {
      expect(
          SleepMath.baselineHours(
              <SleepEntry>[_e('2026-06-29', 7), _e('2026-06-28', 7)], today),
          isNull);
      expect(
          SleepMath.baselineHours(
              <SleepEntry>[
                _e('2026-06-29', 7),
                _e('2026-06-28', 7),
                _e('2026-06-27', 7)
              ],
              today),
          7.0);
    });
  });

  group('Readiness (transparent, sleep-gated)', () {
    test('returns null without sleep — the feature is sleep-gated', () {
      expect(
          computeReadiness(
              lastNightHours: null,
              baselineHours: 7.5,
              runsLast7: 0,
              deficit: 500),
          isNull);
    });

    test('a good night near baseline reads Ready', () {
      final Readiness r = computeReadiness(
          lastNightHours: 7.5,
          baselineHours: 7.5,
          runsLast7: 1,
          deficit: 500)!;
      expect(r.score, 100);
      expect(r.label, 'Ready');
    });

    test('a short night plus load plus steep deficit reads lower, with reasons', () {
      final Readiness r = computeReadiness(
          lastNightHours: 5.0,
          baselineHours: 7.5,
          runsLast7: 4,
          deficit: 800)!;
      // -30 (2.5h gap ×12) -10 (<6h) -10 (load) -10 (deficit) = 40
      expect(r.score, 40);
      expect(r.label, 'Take it easy');
      expect(r.factors.length, 4);
      expect(r.factors.first, contains('5.0h'));
    });

    test('falls back to a 7.5h reference when baseline is unknown', () {
      final Readiness r = computeReadiness(
          lastNightHours: 7.5,
          baselineHours: null,
          runsLast7: 0,
          deficit: 500)!;
      expect(r.score, 100);
    });
  });

  group('Readiness — recovery vitals', () {
    test('elevated resting HR and low HRV vs baseline lower the score', () {
      final Readiness r = computeReadiness(
        lastNightHours: 7.5,
        baselineHours: 7.5,
        runsLast7: 0,
        deficit: 400,
        restingHr: 60,
        baselineRestingHr: 52, // +8 bpm → −15 (capped)
        hrv: 40,
        baselineHrv: 60, // 33% below → −13
      )!;
      expect(r.score, 72); // 100 − 15 (resting HR) − 13 (HRV)
      expect(r.factors.any((String f) => f.contains('Resting HR')), isTrue);
      expect(r.factors.any((String f) => f.contains('HRV')), isTrue);
    });

    test('normal resting HR and HRV do not deduct', () {
      final Readiness r = computeReadiness(
        lastNightHours: 7.5,
        baselineHours: 7.5,
        runsLast7: 0,
        deficit: 400,
        restingHr: 52,
        baselineRestingHr: 52,
        hrv: 60,
        baselineHrv: 60,
      )!;
      expect(r.score, 100);
    });
  });

  group('Recovery baselines + digest', () {
    SleepEntry v(String date, {double? rhr, double? hrv}) => SleepEntry(
        id: date, date: date, asleepMinutes: 450, restingHr: rhr, hrv: hrv);

    test('baselineRestingHr averages recorded nights (≥3)', () {
      final List<SleepEntry> e = <SleepEntry>[
        v('2026-06-29', rhr: 50),
        v('2026-06-28', rhr: 52),
        v('2026-06-27', rhr: 54),
      ];
      expect(SleepMath.baselineRestingHr(e, today), 52);
      expect(
          SleepMath.baselineRestingHr(<SleepEntry>[v('2026-06-29', rhr: 50)],
              today),
          isNull);
    });

    test('digest mentions recovery vitals when present', () {
      final String d = sleepDigest(
          <SleepEntry>[v('2026-06-29', rhr: 51, hrv: 58)], today);
      expect(d, contains('resting HR 51'));
      expect(d, contains('HRV 58'));
    });
  });

  group('Trainer reaction', () {
    test('stays quiet without sleep', () {
      expect(trainerSleepNote(null, 7.5), isNull);
    });
    test('eases after a rough night', () {
      expect(trainerSleepNote(5.0, 7.5), contains('Ease'));
    });
    test('green-lights after a good night', () {
      expect(trainerSleepNote(8.0, 7.5), contains('push'));
    });
    test('says nothing for a middling night', () {
      expect(trainerSleepNote(7.0, 7.5), isNull);
    });
  });

  group('Scale-noise explainer', () {
    test('explains a jump after short sleep', () {
      expect(scaleNoiseNote(1.2, 4.5), contains('likely fluid'));
    });
    test('quiet when the jump is small', () {
      expect(scaleNoiseNote(0.3, 4.5), isNull);
    });
    test('quiet when sleep was fine', () {
      expect(scaleNoiseNote(1.2, 7.5), isNull);
    });
    test('quiet when there is no sleep data', () {
      expect(scaleNoiseNote(1.2, null), isNull);
    });
  });

  group('Digest + JSON', () {
    test('digest is empty without data, populated with it', () {
      expect(sleepDigest(<SleepEntry>[], today), '');
      final String d = sleepDigest(
          <SleepEntry>[_e('2026-06-29', 6.5, deep: 80, rem: 95)], today);
      expect(d, contains('6.5h'));
      expect(d, contains('deep 80m'));
    });

    test('round-trips through JSON', () {
      final SleepEntry e = _e('2026-06-29', 7.25, deep: 70, rem: 90);
      final SleepEntry back = SleepEntry.fromJson(e.toJson());
      expect(back.asleepMinutes, 435);
      expect(back.deepMin, 70);
      expect(decodeSleep('[${jsonEncodeEntry(e)}]').length, 1);
    });
  });

  group('Bedtime recommendation', () {
    // A night with explicit bed/wake clocks so settle time is measurable.
    SleepEntry night(String date, double asleepH, String bed, String wake,
            {double? rhr, double? hrv}) =>
        SleepEntry(
          id: date,
          date: date,
          asleepMinutes: (asleepH * 60).round(),
          bedTime: bed,
          wakeTime: wake,
          restingHr: rhr,
          hrv: hrv,
        );

    test('no data → healthy 8h target + default settle, nothing personalised',
        () {
      final BedtimeRecommendation r =
          recommendBedtime(<SleepEntry>[], today);
      expect(r.sleepNeedMin, 8 * 60);
      expect(r.settleMeasured, isFalse);
      expect(r.nudgeMin, 0);
      // 8h + 25m default settle.
      expect(r.minutesBeforeWake, 8 * 60 + 25);
    });

    test('settle time is measured from the gap between time-in-bed and asleep',
        () {
      // In bed 23:00→07:00 = 8h; asleep 7.5h → 30 min settle each night.
      final List<SleepEntry> e = <SleepEntry>[
        night('2026-06-29', 7.5, '23:00', '07:00'),
        night('2026-06-28', 7.5, '23:00', '07:00'),
        night('2026-06-27', 7.5, '23:00', '07:00'),
      ];
      expect(averageSettleMinutes(e, today), 30);
      final BedtimeRecommendation r = recommendBedtime(e, today);
      expect(r.settleMeasured, isTrue);
      expect(r.settleMin, 30);
    });

    test('elevated resting HR and depressed HRV nudge bedtime earlier', () {
      // Baselines from three calm nights, then a bad last night.
      final List<SleepEntry> e = <SleepEntry>[
        night('2026-06-26', 8, '23:00', '07:00', rhr: 50, hrv: 60),
        night('2026-06-27', 8, '23:00', '07:00', rhr: 50, hrv: 60),
        night('2026-06-28', 8, '23:00', '07:00', rhr: 50, hrv: 60),
        night('2026-06-29', 8, '23:00', '07:00', rhr: 58, hrv: 45),
      ];
      final BedtimeRecommendation r = recommendBedtime(e, today);
      // +15 for high resting HR, +15 for low HRV.
      expect(r.nudgeMin, 30);
    });

    test('bedtimeMinutes works backwards and wraps across midnight', () {
      // Wake 06:30 (390 min), budget 8h30m (510 min) → 22:00 the night before.
      expect(bedtimeMinutes(390, 510), 22 * 60);
      // Exactly midnight wrap.
      expect(bedtimeMinutes(0, 60), 23 * 60);
    });

    test('a higher personal norm overrides the 8h target', () {
      final List<SleepEntry> e = <SleepEntry>[
        night('2026-06-27', 9, '22:00', '07:00'),
        night('2026-06-28', 9, '22:00', '07:00'),
        night('2026-06-29', 9, '22:00', '07:00'),
      ];
      final BedtimeRecommendation r = recommendBedtime(e, today);
      expect(r.sleepNeedMin, 9 * 60);
    });
  });
}

String jsonEncodeEntry(SleepEntry e) {
  final Map<String, dynamic> m = e.toJson();
  final List<String> parts = <String>[];
  m.forEach((String k, dynamic v) {
    parts.add('"$k":${v is String ? '"$v"' : v}');
  });
  return '{${parts.join(',')}}';
}
