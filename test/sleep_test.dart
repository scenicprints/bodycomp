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
}

String jsonEncodeEntry(SleepEntry e) {
  final Map<String, dynamic> m = e.toJson();
  final List<String> parts = <String>[];
  m.forEach((String k, dynamic v) {
    parts.add('"$k":${v is String ? '"$v"' : v}');
  });
  return '{${parts.join(',')}}';
}
