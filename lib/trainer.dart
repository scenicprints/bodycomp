import 'dart:convert';

// ═══════════════════════════════════════════════════════════════════════
// 5K TRAINER — adaptive run/walk coach.
//
// A ladder of run/walk workouts climbs from "barely jogging" to 30 minutes
// continuous (≈5K). The plan is NOT a fixed calendar: after each run the
// engine looks at how it actually went (did you finish, how hard it felt,
// heart rate) and decides whether to ADVANCE, REPEAT, or EASE the next one.
// A few calibration questions pick the starting rung; real imported runs
// refine it from there.
//
// Everything here is pure + unit-tested. Health Connect import, the in-run
// timer UI, and the Claude coaching layer live elsewhere and lean on this.
// ═══════════════════════════════════════════════════════════════════════

enum IntervalKind { warmup, run, walk, cooldown }

class RunInterval {
  final IntervalKind kind;
  final int seconds;
  const RunInterval(this.kind, this.seconds);

  bool get isRun => kind == IntervalKind.run;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'kind': kind.name, 'seconds': seconds};

  factory RunInterval.fromJson(Map<String, dynamic> j) => RunInterval(
        IntervalKind.values.firstWhere((IntervalKind k) => k.name == j['kind'],
            orElse: () => IntervalKind.run),
        (j['seconds'] as num).toInt(),
      );
}

/// One workout = an ordered list of intervals (warmup → repeats → cooldown).
class Workout {
  final int level; // 1-based rung on the ladder
  final String name; // short human label, e.g. "Run 90s / walk 2m × 6"
  final List<RunInterval> intervals;
  const Workout(this.level, this.name, this.intervals);

  int get totalSeconds =>
      intervals.fold(0, (int s, RunInterval i) => s + i.seconds);
  int get runSeconds => intervals
      .where((RunInterval i) => i.isRun)
      .fold(0, (int s, RunInterval i) => s + i.seconds);
  int get runReps => intervals.where((RunInterval i) => i.isRun).length;

  /// Longest single continuous run block, in seconds.
  int get longestRun => intervals
      .where((RunInterval i) => i.isRun)
      .fold(0, (int m, RunInterval i) => i.seconds > m ? i.seconds : m);
}

// ───────────────────────────────────────────────────────────────────────
// THE LADDER
//
// Built once. Each rung lengthens the running and trims the walking, ending
// in a 30-minute continuous run. Every workout brackets the work with a
// 5-minute warmup walk and a 5-minute cooldown walk.
// ───────────────────────────────────────────────────────────────────────

const int _warmup = 300;
const int _cooldown = 300;

Workout _build(int level, String name, int run, int walk, int reps) {
  final List<RunInterval> ivs = <RunInterval>[
    const RunInterval(IntervalKind.warmup, _warmup),
  ];
  for (int i = 0; i < reps; i++) {
    ivs.add(RunInterval(IntervalKind.run, run));
    // No trailing walk after the final rep — straight to cooldown.
    if (i < reps - 1 && walk > 0) {
      ivs.add(RunInterval(IntervalKind.walk, walk));
    }
  }
  ivs.add(const RunInterval(IntervalKind.cooldown, _cooldown));
  return Workout(level, name, ivs);
}

final List<Workout> kRunLadder = <Workout>[
  _build(1, 'Run 60s / walk 90s × 8', 60, 90, 8),
  _build(2, 'Run 90s / walk 2m × 6', 90, 120, 6),
  _build(3, 'Run 2m / walk 2m × 5', 120, 120, 5),
  _build(4, 'Run 3m / walk 90s × 5', 180, 90, 5),
  _build(5, 'Run 5m / walk 3m × 3', 300, 180, 3),
  _build(6, 'Run 8m / walk 3m × 2', 480, 180, 2),
  _build(7, 'Run 10m / walk 3m × 2', 600, 180, 2),
  _build(8, 'Run 15m continuous', 900, 0, 1),
  _build(9, 'Run 20m continuous', 1200, 0, 1),
  _build(10, 'Run 25m continuous', 1500, 0, 1),
  _build(11, 'Run 30m continuous (≈5K)', 1800, 0, 1),
];

int get kMaxLevel => kRunLadder.length;

Workout workoutForLevel(int level) {
  final int l = level.clamp(1, kMaxLevel);
  return kRunLadder[l - 1];
}

// ───────────────────────────────────────────────────────────────────────
// CALIBRATION — map "how long can you run continuously right now" to a rung.
// ───────────────────────────────────────────────────────────────────────

/// [canRunMinutes] = minutes of continuous running the user reports they can
/// do now. Returns the starting level (1..max), placed one notch *below* what
/// they claim so the first session is a confidence-builder, not a wall.
int startingLevel(double canRunMinutes) {
  final double m = canRunMinutes;
  int lvl;
  if (m < 1) {
    lvl = 1;
  } else if (m < 2) {
    lvl = 2;
  } else if (m < 3) {
    lvl = 3;
  } else if (m < 5) {
    lvl = 4;
  } else if (m < 8) {
    lvl = 5;
  } else if (m < 10) {
    lvl = 6;
  } else if (m < 15) {
    lvl = 7;
  } else if (m < 20) {
    lvl = 8;
  } else if (m < 25) {
    lvl = 9;
  } else if (m < 30) {
    lvl = 10;
  } else {
    lvl = 11;
  }
  return lvl.clamp(1, kMaxLevel);
}

// ───────────────────────────────────────────────────────────────────────
// ADAPTIVE PROGRESSION
// ───────────────────────────────────────────────────────────────────────

enum Effort { easy, ok, hard }

Effort effortFromName(String? s) =>
    Effort.values.firstWhere((Effort e) => e.name == s, orElse: () => Effort.ok);

/// What we learn from a finished (or abandoned) run.
class RunOutcome {
  final bool completed; // did they get through all the intervals?
  final Effort effort; // self-reported, or inferred from HR
  final double? avgHrFraction; // avg HR ÷ max HR, 0..1, when known
  const RunOutcome(
      {required this.completed, this.effort = Effort.ok, this.avgHrFraction});
}

/// Decide the next rung given the current one and how the run went.
/// - Didn't finish, or it felt hard → **repeat** the same level.
/// - Finished and it felt easy (and HR wasn't high) → **skip ahead** two.
/// - Otherwise → advance one.
/// Never climbs past the top rung.
int nextLevel(int current, RunOutcome o) {
  final int cur = current.clamp(1, kMaxLevel);
  if (!o.completed || o.effort == Effort.hard) {
    return cur;
  }
  final bool breezed = o.effort == Effort.easy &&
      (o.avgHrFraction == null || o.avgHrFraction! < 0.8);
  final int step = breezed ? 2 : 1;
  return (cur + step).clamp(1, kMaxLevel);
}

/// Heart-rate-derived effort, when we have it (max HR ≈ 220 − age).
/// <70% = easy, 70–85% = ok, >85% = hard.
Effort effortFromHr(double avgHr, int age) {
  final double maxHr = (220 - age).toDouble();
  if (maxHr <= 0) {
    return Effort.ok;
  }
  final double frac = avgHr / maxHr;
  if (frac < 0.70) {
    return Effort.easy;
  }
  if (frac > 0.85) {
    return Effort.hard;
  }
  return Effort.ok;
}

// ───────────────────────────────────────────────────────────────────────
// RUN RECORD — one logged/imported run.
// ───────────────────────────────────────────────────────────────────────

class RunRecord {
  final String id;
  final String date; // 'YYYY-MM-DD'
  final int level; // ladder rung this run was for (0 = freeform)
  final double distanceKm;
  final int durationSec;
  final double? avgHr;
  final String source; // 'healthconnect' | 'manual'
  final bool completed;
  final String effort; // Effort.name

  const RunRecord({
    required this.id,
    required this.date,
    required this.level,
    required this.distanceKm,
    required this.durationSec,
    this.avgHr,
    this.source = 'manual',
    this.completed = true,
    this.effort = 'ok',
  });

  /// Pace in seconds per km (0 if distance unknown).
  double get paceSecPerKm => distanceKm > 0 ? durationSec / distanceKm : 0;

  /// "m:ss /km" pace label, or "—" without distance.
  String get paceLabel {
    if (distanceKm <= 0) {
      return '—';
    }
    final int s = paceSecPerKm.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')} /km';
  }

  RunOutcome get outcome => RunOutcome(
        completed: completed,
        effort: effortFromName(effort),
        avgHrFraction: null,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'date': date,
        'level': level,
        'distanceKm': distanceKm,
        'durationSec': durationSec,
        if (avgHr != null) 'avgHr': avgHr,
        'source': source,
        'completed': completed,
        'effort': effort,
      };

  factory RunRecord.fromJson(Map<String, dynamic> j) => RunRecord(
        id: j['id'] as String,
        date: j['date'] as String,
        level: (j['level'] as num?)?.toInt() ?? 0,
        distanceKm: (j['distanceKm'] as num?)?.toDouble() ?? 0,
        durationSec: (j['durationSec'] as num?)?.toInt() ?? 0,
        avgHr: (j['avgHr'] as num?)?.toDouble(),
        source: (j['source'] as String?) ?? 'manual',
        completed: j['completed'] != false,
        effort: (j['effort'] as String?) ?? 'ok',
      );
}

// ───────────────────────────────────────────────────────────────────────
// TRAINER STATE — current rung + whether calibration is done.
// ───────────────────────────────────────────────────────────────────────

class TrainerState {
  final int level;
  final bool calibrated;
  final bool audioCues; // speak the cues aloud as well as vibrate

  const TrainerState({
    this.level = 1,
    this.calibrated = false,
    this.audioCues = true,
  });

  TrainerState copyWith({int? level, bool? calibrated, bool? audioCues}) =>
      TrainerState(
        level: level ?? this.level,
        calibrated: calibrated ?? this.calibrated,
        audioCues: audioCues ?? this.audioCues,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'level': level,
        'calibrated': calibrated,
        'audioCues': audioCues,
      };

  factory TrainerState.fromJson(Map<String, dynamic> j) => TrainerState(
        level: (j['level'] as num?)?.toInt() ?? 1,
        calibrated: j['calibrated'] == true,
        audioCues: j['audioCues'] != false,
      );

  static TrainerState fromJsonString(String s) {
    try {
      return TrainerState.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const TrainerState();
    }
  }
}

// ───────────────────────────────────────────────────────────────────────
// WEEKLY LOAD — light deficit-awareness signal.
// ───────────────────────────────────────────────────────────────────────

/// Count of runs in the trailing 7 days from [runs], given today's date.
int runsThisWeek(List<RunRecord> runs, DateTime today) {
  final DateTime cutoff = today.subtract(const Duration(days: 7));
  int n = 0;
  for (final RunRecord r in runs) {
    final DateTime? d = DateTime.tryParse(r.date);
    if (d != null && d.isAfter(cutoff)) {
      n++;
    }
  }
  return n;
}

/// A gentle fueling nudge when run volume is high against a steep deficit.
/// Returns null when nothing's worth saying. [dailyDeficit] is kcal/day
/// (positive = eating under maintenance).
String? fuelingFlag(int runsLast7, double dailyDeficit) {
  if (runsLast7 >= 3 && dailyDeficit >= 600) {
    return 'You ran $runsLast7× this week on a ${dailyDeficit.round()}-kcal '
        'daily deficit — eat a bit more on run days to protect recovery.';
  }
  return null;
}
