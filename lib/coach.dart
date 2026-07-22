import 'main.dart';
import 'food.dart';
import 'sleep.dart';
import 'trainer.dart';

// ═══════════════════════════════════════════════════════════════════════
// COACH — on-device coaching. No LLM, no API, no key: pure rules over the
// user's OWN computed numbers (targets, TDEE, smoothed trends, adherence,
// sleep, runs). Instant, free, offline, and deterministic — the same data
// always yields the same read, so it can be unit-tested.
//
// Output is plain text: a one-line headline, then a few marked points —
//   ✓ working, keep it   ⚠ a real leak to fix   → do this   • context
// Every line fires only when the numbers actually support it; nothing is
// said just to fill space.
// ═══════════════════════════════════════════════════════════════════════

/// A saved coaching read, persisted per period so it survives tab switches
/// (kept the historical name so stored JSON keeps loading unchanged).
class AdvisorInsight {
  final String kind; // 'daily' | 'weekly' | 'run'
  final String periodKey; // day / week-start / run id
  final String text;
  final int createdAtMs;
  AdvisorInsight(
      {required this.kind,
      required this.periodKey,
      required this.text,
      required this.createdAtMs});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'periodKey': periodKey,
        'text': text,
        'createdAtMs': createdAtMs,
      };
  factory AdvisorInsight.fromJson(Map<String, dynamic> j) => AdvisorInsight(
        kind: j['kind'] as String,
        periodKey: j['periodKey'] as String,
        text: j['text'] as String,
        createdAtMs: (j['createdAtMs'] as num?)?.toInt() ?? 0,
      );
}

/// The numbers a daily/weekly read is built from — computed once, pure, and
/// directly testable.
class CoachFacts {
  final bool weekly;
  final MacroTargets t;
  final double tdee;

  final int eatenDays;
  final double avgCal, avgProtein, avgFiber;
  final int proteinShortDays, fiberShortDays;
  final int daysSinceFood;

  // Smoothed weight/body trends. *Prev = the prior 7 days (daily view);
  // *Then = ~4 weeks ago (weekly view).
  final double? wNow, wPrev, wThen;
  final double? leanNow, leanPrev, leanThen;
  final double? bfNow, bfPrev;
  final double? fatNow, fatThen;
  final double? swing; // raw 7-day top-to-bottom weight spread

  final DateTime? goalDate;
  final bool plateau;

  final double? lastNightHours, baselineHours;
  final bool ranToday;

  const CoachFacts({
    required this.weekly,
    required this.t,
    required this.tdee,
    required this.eatenDays,
    required this.avgCal,
    required this.avgProtein,
    required this.avgFiber,
    required this.proteinShortDays,
    required this.fiberShortDays,
    required this.daysSinceFood,
    this.wNow,
    this.wPrev,
    this.wThen,
    this.leanNow,
    this.leanPrev,
    this.leanThen,
    this.bfNow,
    this.bfPrev,
    this.fatNow,
    this.fatThen,
    this.swing,
    this.goalDate,
    this.plateau = false,
    this.lastNightHours,
    this.baselineHours,
    this.ranToday = false,
  });

  static CoachFacts build(
    UserCalibration cal,
    List<DailyLog> logs,
    List<FoodEntry> foods,
    Set<String> fasted, {
    required bool weekly,
    List<SleepEntry> sleep = const <SleepEntry>[],
    List<RunRecord> runs = const <RunRecord>[],
    DateTime? asOf,
  }) {
    final DateTime now = asOf ?? DateTime.now();
    final MacroTargets t = MacroTargets.compute(cal, logs, foods, fasted);
    final Map<String, double> byDateCal = FoodMath.caloriesByDate(foods);
    final double tdee = logs.isEmpty
        ? 0
        : MathEngine.activeTdee(logs, cal.activityMult,
            caloriesByDate: byDateCal, fastedDates: fasted);

    double? smooth(double Function(DailyLog) sel, int endDaysAgo, int win) {
      final String hi = formatDate(now.subtract(Duration(days: endDaysAgo)));
      final String lo =
          formatDate(now.subtract(Duration(days: endDaysAgo + win)));
      final List<double> xs = logs
          .where((DailyLog l) =>
              l.date.compareTo(lo) > 0 && l.date.compareTo(hi) <= 0)
          .map(sel)
          .toList();
      if (xs.isEmpty) {
        return null;
      }
      return xs.reduce((double a, double b) => a + b) / xs.length;
    }

    double wOf(DailyLog l) => l.weight;
    double bfOf(DailyLog l) => l.bf * 100;
    double leanOf(DailyLog l) => l.lbm;
    double fatOf(DailyLog l) => l.fatMass;

    // Raw 7-day swing → how water-dominated the scale is right now.
    final String weekAgo = formatDate(now.subtract(const Duration(days: 7)));
    final List<double> last7 = logs
        .where((DailyLog l) => l.date.compareTo(weekAgo) > 0)
        .map(wOf)
        .toList();
    double? swing;
    if (last7.length >= 2) {
      double lo = last7.first, hi = last7.first;
      for (final double w in last7) {
        if (w < lo) lo = w;
        if (w > hi) hi = w;
      }
      swing = hi - lo;
    }

    // Adherence window.
    final int window = weekly ? 30 : 10;
    int eaten = 0, proteinShort = 0, fiberShort = 0;
    double sumCal = 0, sumP = 0, sumFiber = 0;
    for (int i = 0; i < window; i++) {
      final String d = formatDate(now.subtract(Duration(days: i)));
      if ((byDateCal[d] ?? 0) <= 0) {
        continue;
      }
      final DayTotals dt = FoodMath.totals(foods, d);
      eaten++;
      sumCal += dt.calories;
      sumP += dt.protein;
      final double fiber = dt.nutrients['fiber'] ?? 0;
      sumFiber += fiber;
      if (t.protein > 0 && dt.protein < t.protein * 0.85) proteinShort++;
      if (t.fiber > 0 && fiber < t.fiber * 0.70) fiberShort++;
    }
    final double inv = eaten > 0 ? 1.0 / eaten : 0;

    int daysSinceFood = -1;
    for (int i = 0; i <= 60; i++) {
      if ((byDateCal[formatDate(now.subtract(Duration(days: i)))] ?? 0) > 0) {
        daysSinceFood = i;
        break;
      }
    }

    final String todayStr = formatDate(now);
    final bool ranToday = runs.any((RunRecord r) => r.date == todayStr);
    final SleepEntry? lastNight = SleepMath.latest(sleep);

    return CoachFacts(
      weekly: weekly,
      t: t,
      tdee: tdee,
      eatenDays: eaten,
      avgCal: sumCal * inv,
      avgProtein: sumP * inv,
      avgFiber: sumFiber * inv,
      proteinShortDays: proteinShort,
      fiberShortDays: fiberShort,
      daysSinceFood: daysSinceFood,
      wNow: smooth(wOf, 0, 7),
      wPrev: smooth(wOf, 7, 7),
      wThen: smooth(wOf, 28, 7),
      leanNow: smooth(leanOf, 0, 7),
      leanPrev: smooth(leanOf, 7, 7),
      leanThen: smooth(leanOf, 28, 7),
      bfNow: smooth(bfOf, 0, 7),
      bfPrev: smooth(bfOf, 7, 7),
      fatNow: smooth(fatOf, 0, 7),
      fatThen: smooth(fatOf, 28, 7),
      swing: swing,
      goalDate: MathEngine.goalDate(logs, cal.targetBf),
      plateau: MathEngine.isPlateau(logs),
      lastNightHours: lastNight?.hours,
      baselineHours: SleepMath.baselineHours(sleep, now),
      ranToday: ranToday,
    );
  }
}

class Coach {
  // ── Daily check-in ────────────────────────────────────────────────────
  static String daily(CoachFacts f) {
    final List<String> out = <String>[];
    out.add(_dailyHeadline(f));

    if (f.eatenDays >= 3) {
      // Protein — the lever that protects muscle on a cut.
      if (f.t.protein > 0 && f.avgProtein >= f.t.protein * 0.98) {
        out.add('✓ Protein ~${_r0(f.avgProtein)} g/day (target '
            '${_r0(f.t.protein)}) — that\'s what holds your muscle on a '
            'deficit. Keep it.');
      } else if (f.proteinShortDays >= (f.eatenDays / 2).ceil()) {
        out.add('⚠ Protein ~${_r0(f.avgProtein)} g/day, under your '
            '${_r0(f.t.protein)} g target ${f.proteinShortDays}/${f.eatenDays} '
            'days. On a cut that\'s muscle at risk — anchor every meal with a '
            'protein.');
      }
      // Fiber.
      if (f.t.fiber > 0 && f.fiberShortDays >= (f.eatenDays / 2).ceil()) {
        out.add('⚠ Fiber ~${_r0(f.avgFiber)} g/day vs your ${_r0(f.t.fiber)} g '
            'target, short ${f.fiberShortDays}/${f.eatenDays} days. Add a '
            'vegetable or fruit to two meals.');
      }
      // Calorie reality vs the intended deficit.
      if (f.t.calories > 0 && f.avgCal > f.t.calories + 250) {
        out.add('⚠ Averaging ${_r0(f.avgCal)} cal vs your ${_r0(f.t.calories)} '
            'target — the deficit is thinner than planned. Trim about '
            '${_r0(f.avgCal - f.t.calories)} cal/day.');
      } else if (f.t.calories > 0 && f.avgCal > 0 &&
          f.avgCal < f.t.calories - 450) {
        out.add('• Intake ~${_r0(f.avgCal)} cal is well under target — fine '
            'short-term, but too steep a cut stalls recomp and costs muscle.');
      }
    }

    // Sleep → today's effort.
    if (f.lastNightHours != null &&
        f.baselineHours != null &&
        f.lastNightHours! < f.baselineHours! - 1.0) {
      out.add('→ Short sleep last night (${_r1(f.lastNightHours!)}h vs ~'
          '${_r1(f.baselineHours!)}h usual)${f.ranToday ? ' and you already ran' : ''}'
          ' — expect a higher heart rate today; keep any effort easy and hit '
          'protein early.');
    }

    if (out.length == 1 && f.eatenDays < 3) {
      out.add('• Only ${f.eatenDays} logged day(s) in range — log a few days '
          'of food and weight and the read gets sharper.');
    }
    return _cap(out, 4);
  }

  static String _dailyHeadline(CoachFacts f) {
    if (f.wNow == null || f.wPrev == null) {
      return 'Not enough recent weigh-ins to call a trend — the read below is '
          'from your intake and sleep.';
    }
    final double dW = f.wNow! - f.wPrev!;
    final double? dLean =
        (f.leanNow != null && f.leanPrev != null) ? f.leanNow! - f.leanPrev! : null;
    final bool noisy = f.swing != null && f.swing! > 4;
    if (noisy) {
      return 'The scale swung ${_r1(f.swing!)} lb this week — that\'s water, '
          'not fat. Ignore the number and judge by the behaviours below.';
    }
    if (dW < -0.3 && dLean != null && dLean >= -0.2) {
      return 'Recomp is working — weight down ${_r1(dW.abs())} lb/wk and lean '
          'mass holding. That\'s fat leaving, not muscle.';
    }
    if (dW < -0.3 && dLean != null && dLean < -0.5) {
      return 'Weight is down ${_r1(dW.abs())} lb/wk but lean mass slipped '
          '${_r1(dLean.abs())} lb — some of that loss is muscle, not just fat.';
    }
    if (dW > 0.4) {
      return 'Weight ticked up ${_r1(dW)} lb/wk (7-day avg) — worth a look at '
          'the week\'s intake below.';
    }
    return 'Holding steady week over week. Steady is fine — the points below '
        'are where the movement is.';
  }

  // ── Weekly review ─────────────────────────────────────────────────────
  static String weekly(CoachFacts f) {
    final List<String> out = <String>[];
    out.add(_weeklyHeadline(f));

    // Biggest win worth naming.
    if (f.eatenDays >= 5 && f.t.protein > 0 &&
        f.avgProtein >= f.t.protein * 0.98) {
      out.add('✓ Protein has held at ~${_r0(f.avgProtein)} g/day all period — '
          'that\'s the single biggest reason any weight you lose comes off as '
          'fat. Don\'t let it slip.');
    }
    // Biggest leak.
    if (f.eatenDays >= 5 && f.t.fiber > 0 &&
        f.fiberShortDays >= (f.eatenDays / 2).ceil()) {
      out.add('⚠ Fiber is the leak — under ${_r0(f.t.fiber)} g on '
          '${f.fiberShortDays}/${f.eatenDays} logged days (avg '
          '${_r0(f.avgFiber)} g). Fixing this helps satiety, digestion and the '
          'deficit at once.');
    }
    if (f.eatenDays >= 5 && f.t.calories > 0 && f.avgCal > f.t.calories + 200) {
      out.add('⚠ Intake averaged ${_r0(f.avgCal)} cal vs a ${_r0(f.t.calories)} '
          'target — about ${_r0((f.avgCal - f.t.calories) * 7)} cal of "extra" '
          'a week. That\'s the gap between your planned pace and your real one.');
    }
    if (f.plateau) {
      out.add('• The rolling weight average has been flat ~10 days. If lean '
          'mass is holding, that\'s a recomp plateau — drop intake ~150 cal or '
          'add a session before touching protein.');
    }
    if (f.goalDate != null) {
      out.add('• At the current smoothed pace you hit your target body-fat '
          'around ${monthName(f.goalDate!.month)} ${f.goalDate!.day}, '
          '${f.goalDate!.year}.');
    }
    if (out.length == 1) {
      out.add('• Not enough smoothed history yet for month-scale patterns — a '
          'couple more weeks of weigh-ins and this fills in.');
    }
    return _cap(out, 5);
  }

  static String _weeklyHeadline(CoachFacts f) {
    final double? dW =
        (f.wNow != null && f.wThen != null) ? f.wNow! - f.wThen! : null;
    final double? dLean = (f.leanNow != null && f.leanThen != null)
        ? f.leanNow! - f.leanThen!
        : null;
    final double? dFat =
        (f.fatNow != null && f.fatThen != null) ? f.fatNow! - f.fatThen! : null;
    if (dFat != null && dLean != null && dFat < -0.5 && dLean >= 0) {
      return 'Textbook recomp over ~4 weeks — fat mass down '
          '${_r1(dFat.abs())} lb while lean mass held/rose ${_r1(dLean)} lb. '
          'Whatever you\'re doing, keep doing it.';
    }
    if (dFat != null && dLean != null && dFat < 0 && dLean < -1) {
      return 'Fat is down ${_r1(dFat.abs())} lb over ~4 weeks but lean mass '
          'fell ${_r1(dLean.abs())} lb too — you\'re losing muscle you don\'t '
          'need to. Protein and easier deficit, below.';
    }
    if (dW != null && dW > 1) {
      return 'Up ${_r1(dW)} lb over ~4 weeks on the smoothed trend — that\'s '
          'real, not water. Time to tighten the week\'s intake.';
    }
    if (dW != null && dW < -1) {
      return 'Down ${_r1(dW.abs())} lb over ~4 weeks (smoothed) — steady, '
          'sustainable progress.';
    }
    return 'Roughly flat over the last ~4 weeks on the smoothed trend.';
  }

  // ── Run coach ─────────────────────────────────────────────────────────
  static String run(
    RunRecord r, {
    List<SleepEntry> sleep = const <SleepEntry>[],
    int trainerLevel = 0,
    DateTime? asOf,
  }) {
    final DateTime now = asOf ?? DateTime.now();
    final List<String> out = <String>[];

    final double? resting = SleepMath.baselineRestingHr(sleep, now) ??
        SleepMath.latest(sleep)?.restingHr;
    final double km = r.distanceKm;
    final double min = r.durationSec / 60.0;

    // Effort from THEIR resting HR, mirroring the leveling thresholds.
    if (r.avgHr != null && resting != null && resting > 0) {
      final double reserve = r.avgHr! - resting;
      final String call = reserve <= 70
          ? 'controlled — comfortably aerobic'
          : reserve >= 110
              ? 'a grind — well into hard territory'
              : 'a solid, honest effort';
      out.add('Effort: ${call}. Average HR ${_r0(r.avgHr!)} vs your resting '
          '~${_r0(resting)} (${_r0(reserve)} bpm above rest).');
      if (reserve <= 70 && r.completed) {
        out.add('→ That was easy for you — next run, move up a level.');
      } else if (reserve >= 110) {
        out.add('→ That cost you. Hold this level (or drop one) and let the '
            'pace come to you before pushing up.');
      } else {
        out.add('→ Right in the training sweet spot — hold here and it\'ll '
            'keep getting easier at the same pace.');
      }
    } else {
      out.add('No heart-rate data on this run, so effort is a guess — log with '
          'the watch for a real read.');
    }

    if (km > 0 && min > 0) {
      final double paceMinPerKm = min / km;
      out.add('• ${_r1(km)} km in ${_r0(min)} min — ~${_pace(paceMinPerKm)}/km.');
    }

    // Sleep tie-in only when it plausibly hit the run.
    final SleepEntry? lastNight = SleepMath.latest(sleep);
    final double? baseHours = SleepMath.baselineHours(sleep, now);
    if (lastNight != null &&
        baseHours != null &&
        lastNight.hours < baseHours - 1.0 &&
        r.avgHr != null &&
        resting != null) {
      out.add('• You ran on ${_r1(lastNight.hours)}h sleep (usual '
          '~${_r1(baseHours)}h) — some of that heart rate is fatigue, not '
          'fitness. Don\'t read too much into a high number today.');
    }
    return _cap(out, 4);
  }

  // ── formatting helpers ────────────────────────────────────────────────
  static String _cap(List<String> lines, int max) =>
      lines.take(max).join('\n');

  static String _r0(double v) => v.isFinite ? v.round().toString() : '0';
  static String _r1(double v) => v.isFinite ? v.toStringAsFixed(1) : '0.0';

  static String _pace(double minPerKm) {
    if (!minPerKm.isFinite || minPerKm <= 0) {
      return '—';
    }
    final int m = minPerKm.floor();
    final int s = ((minPerKm - m) * 60).round();
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
