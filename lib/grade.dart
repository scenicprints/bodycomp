import 'dart:math';

import 'main.dart';

// ═══════════════════════════════════════════════════════════════════════
// GRADE — am I going to hit my goal, on time?
//
// A single hard-set target date is computed once and frozen. Everything here
// then measures one thing: how far along you ARE versus how far along you
// SHOULD be on that date. On schedule is an A-; ahead earns A and A+; behind
// walks down through B/C/D with full +/- steps.
//
// Also home to the Navy-method body-fat calculation and the rule that decides
// when to ask for a fresh waist measurement.
// ═══════════════════════════════════════════════════════════════════════

/// Sustainable ceiling on fat loss: never demand more than 1% of body weight
/// per week, however aggressive the deficit setting is.
const double kMaxWeeklyLossFraction = 0.01;

/// Real-life padding on the deadline — plateaus, holidays, bad weeks. Keeps
/// the date reachable rather than theoretically perfect.
const double kDeadlineBuffer = 1.15;

/// Pounds of NEW progress (below the weight at the last measurement) that
/// triggers a fresh waist measurement. Measured against the lowest weight
/// ever recorded, so regaining and re-losing the same pounds can't re-trigger.
const double kMeasureEveryLb = 4.0;

// ── Navy method ─────────────────────────────────────────────────────────

/// One waist measurement and the body fat it produced.
class BodyMeasurement {
  final String date; // 'YYYY-MM-DD'
  final double waistIn;
  final double neckIn;
  final double? hipIn; // women only
  final double weightAtMeasure; // the weight this was taken at
  final double bodyFat; // 0..1

  const BodyMeasurement({
    required this.date,
    required this.waistIn,
    required this.neckIn,
    this.hipIn,
    required this.weightAtMeasure,
    required this.bodyFat,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'waistIn': waistIn,
        'neckIn': neckIn,
        if (hipIn != null) 'hipIn': hipIn,
        'weightAtMeasure': weightAtMeasure,
        'bodyFat': bodyFat,
      };

  factory BodyMeasurement.fromJson(Map<String, dynamic> j) => BodyMeasurement(
        date: j['date'] as String,
        waistIn: (j['waistIn'] as num).toDouble(),
        neckIn: (j['neckIn'] as num).toDouble(),
        hipIn: (j['hipIn'] as num?)?.toDouble(),
        weightAtMeasure: (j['weightAtMeasure'] as num?)?.toDouble() ?? 0,
        bodyFat: (j['bodyFat'] as num).toDouble(),
      );
}

double _log10(double x) => log(x) / ln10;

/// US Navy body-fat estimate, imperial inches. Returns 0..1, or null when the
/// inputs can't produce a real answer (the log needs waist > neck).
double? navyBodyFat({
  required double waistIn,
  required double neckIn,
  required double heightIn,
  double? hipIn,
  bool female = false,
}) {
  if (waistIn <= 0 || neckIn <= 0 || heightIn <= 0) {
    return null;
  }
  double pct;
  if (female) {
    final double hips = hipIn ?? 0;
    if (hips <= 0 || waistIn + hips - neckIn <= 0) {
      return null;
    }
    pct = 163.205 * _log10(waistIn + hips - neckIn) -
        97.684 * _log10(heightIn) -
        78.387;
  } else {
    if (waistIn - neckIn <= 0) {
      return null;
    }
    pct = 86.010 * _log10(waistIn - neckIn) - 70.041 * _log10(heightIn) + 36.76;
  }
  if (!pct.isFinite || pct <= 0 || pct >= 75) {
    return null;
  }
  return pct / 100.0;
}

/// Should the app ask for a new waist measurement?
///
/// Purely weight-driven, and only on genuine NEW lows: it compares the lowest
/// weight ever recorded against the weight at the last measurement. Losing 4 lb
/// you already lost once doesn't count, so a gain-then-loss can't re-trigger
/// it — but a fast drop can legitimately trigger it twice in one week.
bool shouldMeasure({
  required List<DailyLog> logs,
  required List<BodyMeasurement> measurements,
  double everyLb = kMeasureEveryLb,
}) {
  if (logs.isEmpty) {
    return false;
  }
  final double lowest = logs
      .map((DailyLog l) => l.weight)
      .reduce((double a, double b) => min(a, b));
  if (measurements.isEmpty) {
    return true; // never measured — ask once to establish the baseline
  }
  final BodyMeasurement last = measurements.last;
  final double since = last.weightAtMeasure - lowest;
  return since >= everyLb;
}

/// How many pounds until the next measurement prompt (0 when it's due).
double lbUntilMeasure({
  required List<DailyLog> logs,
  required List<BodyMeasurement> measurements,
  double everyLb = kMeasureEveryLb,
}) {
  if (logs.isEmpty || measurements.isEmpty) {
    return 0;
  }
  final double lowest = logs
      .map((DailyLog l) => l.weight)
      .reduce((double a, double b) => min(a, b));
  final double since = measurements.last.weightAtMeasure - lowest;
  return max(0, everyLb - since);
}

// ── the hard-set deadline ───────────────────────────────────────────────

/// Weeks needed to reach the goal at a sustainable, genuinely reachable pace.
/// The deficit sets the pace, capped so it can never demand an elite rate, and
/// padded for real life.
double weeksToGoal({
  required double weight,
  required double lbm,
  required double currentBf,
  required double targetBf,
  required int deficit,
}) {
  if (currentBf <= targetBf) {
    return 0;
  }
  final double goalWeight = lbm / (1 - targetBf);
  final double fatToLose = weight * currentBf - goalWeight * targetBf;
  if (fatToLose <= 0) {
    return 0;
  }
  // A pound of fat is ~3500 cal; cap the pace at 1% of body weight a week.
  final double fromDeficit = deficit * 7 / 3500.0;
  final double ceiling = weight * kMaxWeeklyLossFraction;
  final double weekly = max(0.25, min(fromDeficit, ceiling));
  return (fatToLose / weekly) * kDeadlineBuffer;
}

/// The date to aim at, computed once and then frozen by the caller.
DateTime goalDeadline({
  required DateTime from,
  required double weight,
  required double lbm,
  required double currentBf,
  required double targetBf,
  required int deficit,
}) {
  final double weeks = weeksToGoal(
      weight: weight,
      lbm: lbm,
      currentBf: currentBf,
      targetBf: targetBf,
      deficit: deficit);
  return from.add(Duration(days: (weeks * 7).round()));
}

// ── the grade ───────────────────────────────────────────────────────────

class GoalGrade {
  final String letter; // 'A+' … 'F', or '' when ungradeable
  final int score; // 100 = exactly on schedule
  final double expected; // 0..1 how far along you should be
  final double actual; // 0..1 how far along you are
  final DateTime? projected; // when you'll arrive at the current pace
  final int daysEarly; // + early, − behind (vs the deadline)
  final String summary;
  final bool gradeable;
  final int? deltaScore; // vs the previous period: the better/worse arrow

  const GoalGrade({
    required this.letter,
    required this.score,
    required this.expected,
    required this.actual,
    this.projected,
    this.daysEarly = 0,
    required this.summary,
    required this.gradeable,
    this.deltaScore,
  });

  bool get improving => (deltaScore ?? 0) > 0;
  bool get slipping => (deltaScore ?? 0) < 0;
}

/// Letter for a schedule score. 100 = dead on the deadline = A-.
/// Ahead earns A/A+; behind steps down through B, C and D with full +/-.
String letterFor(int score) {
  if (score >= 120) return 'A+';
  if (score >= 108) return 'A';
  if (score >= 98) return 'A-';
  if (score >= 92) return 'B+';
  if (score >= 86) return 'B';
  if (score >= 80) return 'B-';
  if (score >= 74) return 'C+';
  if (score >= 68) return 'C';
  if (score >= 62) return 'C-';
  if (score >= 55) return 'D+';
  if (score >= 48) return 'D';
  if (score >= 40) return 'D-';
  return 'F';
}

/// Grade progress toward the goal against the frozen deadline.
///
/// Body fat is the real goal so it carries most of the weight; scale weight
/// carries the rest. Both are read from smoothed averages, never a single
/// weigh-in.
GoalGrade computeGrade({
  required UserCalibration cal,
  required List<DailyLog> logs,
  required DateTime? startDate,
  required DateTime? deadline,
  DateTime? asOf,
  double bfWeight = 0.6,
}) {
  final DateTime now = asOf ?? DateTime.now();
  if (logs.length < 3 || startDate == null || deadline == null) {
    return const GoalGrade(
      letter: '',
      score: 0,
      expected: 0,
      actual: 0,
      summary: 'Not enough data to grade yet — keep logging and this fills in.',
      gradeable: false,
    );
  }

  // Smoothed current readings (last 7 days of logs).
  final List<DailyLog> sorted = List<DailyLog>.of(logs)
    ..sort((DailyLog a, DailyLog b) => a.date.compareTo(b.date));
  List<DailyLog> tail(int n) => sorted.sublist(max(0, sorted.length - n));
  double avg(List<DailyLog> xs, double Function(DailyLog) sel) =>
      xs.map(sel).reduce((double a, double b) => a + b) / xs.length;

  final List<DailyLog> recent = tail(7);
  final double curBf = avg(recent, (DailyLog l) => l.bf);
  final double curW = avg(recent, (DailyLog l) => l.weight);

  final double startBf = cal.startBf;
  final double startW = cal.startWeight;
  final double goalBf = cal.targetBf;
  final double goalW = MathEngine.dynamicTargetWeight(
      avg(recent, (DailyLog l) => l.lbm), goalBf);

  // How far along, on each axis.
  double frac(double start, double cur, double goal) {
    final double span = start - goal;
    if (span.abs() < 1e-6) return 1;
    return ((start - cur) / span).clamp(-1.0, 2.0);
  }

  final double fBf = frac(startBf, curBf, goalBf);
  final double fW = frac(startW, curW, goalW);
  final double actual = fBf * bfWeight + fW * (1 - bfWeight);

  // How far along you should be by now.
  final int totalDays = deadline.difference(startDate).inDays;
  final int elapsed = now.difference(startDate).inDays;
  if (totalDays <= 0) {
    return const GoalGrade(
      letter: '',
      score: 0,
      expected: 0,
      actual: 0,
      summary: 'Set a goal date to start grading.',
      gradeable: false,
    );
  }
  final double expected = (elapsed / totalDays).clamp(0.0, 1.0);

  // Too early to judge fairly — a few days in, any number is noise.
  if (elapsed < 7) {
    return GoalGrade(
      letter: '',
      score: 0,
      expected: expected,
      actual: actual,
      summary: 'Grading starts after your first week.',
      gradeable: false,
    );
  }

  final int score = expected <= 0
      ? 100
      : (actual / expected * 100).clamp(0.0, 200.0).round();

  // Where this pace actually lands you.
  DateTime? projected;
  int daysEarly = 0;
  if (actual > 0.01) {
    final int projDays = (elapsed / actual).round();
    projected = startDate.add(Duration(days: projDays));
    daysEarly = deadline.difference(projected).inDays;
  }

  final String when = projected == null
      ? 'no measurable progress yet'
      : daysEarly > 0
          ? 'on pace to arrive $daysEarly days early'
          : daysEarly < 0
              ? 'on pace to arrive ${-daysEarly} days late'
              : 'on pace to arrive exactly on time';

  final double bfPts = (startBf - curBf) * 100;
  final double lbDown = startW - curW;
  final String moved = (bfPts > 0.05 || lbDown > 0.2)
      ? 'Body fat ${bfPts >= 0 ? 'down' : 'up'} '
          '${bfPts.abs().toStringAsFixed(1)} pts and '
          '${lbDown.abs().toStringAsFixed(1)} lb '
          '${lbDown >= 0 ? 'off' : 'on'} since you started — '
      : '';

  return GoalGrade(
    letter: letterFor(score),
    score: score,
    expected: expected,
    actual: actual,
    projected: projected,
    daysEarly: daysEarly,
    summary: '$moved$when.',
    gradeable: true,
  );
}

/// The same grade a month ago, so the card can show better/worse.
GoalGrade gradeWithTrend({
  required UserCalibration cal,
  required List<DailyLog> logs,
  required DateTime? startDate,
  required DateTime? deadline,
  DateTime? asOf,
}) {
  final DateTime now = asOf ?? DateTime.now();
  final GoalGrade nowGrade = computeGrade(
      cal: cal,
      logs: logs,
      startDate: startDate,
      deadline: deadline,
      asOf: now);
  if (!nowGrade.gradeable) {
    return nowGrade;
  }
  final DateTime then = now.subtract(const Duration(days: 28));
  final String cutoff = formatDate(then);
  final List<DailyLog> before =
      logs.where((DailyLog l) => l.date.compareTo(cutoff) <= 0).toList();
  if (before.length < 3) {
    return nowGrade;
  }
  final GoalGrade thenGrade = computeGrade(
      cal: cal,
      logs: before,
      startDate: startDate,
      deadline: deadline,
      asOf: then);
  if (!thenGrade.gradeable) {
    return nowGrade;
  }
  return GoalGrade(
    letter: nowGrade.letter,
    score: nowGrade.score,
    expected: nowGrade.expected,
    actual: nowGrade.actual,
    projected: nowGrade.projected,
    daysEarly: nowGrade.daysEarly,
    summary: nowGrade.summary,
    gradeable: true,
    deltaScore: nowGrade.score - thenGrade.score,
  );
}
