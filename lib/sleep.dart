import 'dart:convert';

// ═══════════════════════════════════════════════════════════════════════
// SLEEP — imported from Health Connect (Pixel Watch), never manual.
//
// Sleep is an OPTIONAL input: when it's present the rest of the app listens
// to it (coaching, trainer readiness, scale-noise context); when it's absent
// nothing waits on it and nothing breaks. Sleep NEVER rewrites the raw
// numbers (weight, lean mass, TDEE) — it only informs guidance.
//
// Pure model + math here; unit-tested. Health Connect I/O and UI live in
// main.dart.
// ═══════════════════════════════════════════════════════════════════════

class SleepEntry {
  final String id;
  final String date; // wake date 'YYYY-MM-DD' (the morning the night ended)
  final int asleepMinutes; // total time actually asleep
  final int? deepMin;
  final int? remMin;
  final int? lightMin;
  final int? awakeMin;
  final double? avgHr; // overnight average heart rate, if recorded
  // Recovery vitals (overnight), when Health Connect has them.
  final double? restingHr;
  final double? hrv; // heart-rate variability (ms)
  final double? respiratoryRate; // breaths/min
  final double? skinTemp; // °C delta or absolute, as provided
  final String bedTime; // 'HH:mm' for display (may be empty)
  final String wakeTime; // 'HH:mm' for display (may be empty)
  final String source; // 'healthconnect'

  const SleepEntry({
    required this.id,
    required this.date,
    required this.asleepMinutes,
    this.deepMin,
    this.remMin,
    this.lightMin,
    this.awakeMin,
    this.avgHr,
    this.restingHr,
    this.hrv,
    this.respiratoryRate,
    this.skinTemp,
    this.bedTime = '',
    this.wakeTime = '',
    this.source = 'healthconnect',
  });

  double get hours => asleepMinutes / 60.0;

  bool get hasStages =>
      (deepMin ?? 0) + (remMin ?? 0) + (lightMin ?? 0) > 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'date': date,
        'asleepMinutes': asleepMinutes,
        if (deepMin != null) 'deepMin': deepMin,
        if (remMin != null) 'remMin': remMin,
        if (lightMin != null) 'lightMin': lightMin,
        if (awakeMin != null) 'awakeMin': awakeMin,
        if (avgHr != null) 'avgHr': avgHr,
        if (restingHr != null) 'restingHr': restingHr,
        if (hrv != null) 'hrv': hrv,
        if (respiratoryRate != null) 'respiratoryRate': respiratoryRate,
        if (skinTemp != null) 'skinTemp': skinTemp,
        if (bedTime.isNotEmpty) 'bedTime': bedTime,
        if (wakeTime.isNotEmpty) 'wakeTime': wakeTime,
        'source': source,
      };

  factory SleepEntry.fromJson(Map<String, dynamic> j) => SleepEntry(
        id: j['id'] as String,
        date: j['date'] as String,
        asleepMinutes: (j['asleepMinutes'] as num?)?.toInt() ?? 0,
        deepMin: (j['deepMin'] as num?)?.toInt(),
        remMin: (j['remMin'] as num?)?.toInt(),
        lightMin: (j['lightMin'] as num?)?.toInt(),
        awakeMin: (j['awakeMin'] as num?)?.toInt(),
        avgHr: (j['avgHr'] as num?)?.toDouble(),
        restingHr: (j['restingHr'] as num?)?.toDouble(),
        hrv: (j['hrv'] as num?)?.toDouble(),
        respiratoryRate: (j['respiratoryRate'] as num?)?.toDouble(),
        skinTemp: (j['skinTemp'] as num?)?.toDouble(),
        bedTime: (j['bedTime'] as String?) ?? '',
        wakeTime: (j['wakeTime'] as String?) ?? '',
        source: (j['source'] as String?) ?? 'healthconnect',
      );
}

class SleepMath {
  static List<SleepEntry> _within(
      List<SleepEntry> entries, DateTime today, int days) {
    final DateTime cutoff = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: days - 1));
    return entries.where((SleepEntry e) {
      final DateTime? d = DateTime.tryParse(e.date);
      return d != null && !d.isBefore(cutoff);
    }).toList();
  }

  /// Most recent night, or null if there is none.
  static SleepEntry? latest(List<SleepEntry> entries) {
    SleepEntry? best;
    for (final SleepEntry e in entries) {
      if (best == null || e.date.compareTo(best.date) > 0) {
        best = e;
      }
    }
    return best;
  }

  /// Average asleep hours over the trailing [days] window (null if no nights).
  static double? averageHours(
      List<SleepEntry> entries, DateTime today, int days) {
    final List<SleepEntry> w = _within(entries, today, days);
    if (w.isEmpty) {
      return null;
    }
    final double total =
        w.fold(0.0, (double s, SleepEntry e) => s + e.hours);
    return total / w.length;
  }

  /// The user's own sleep norm — a 14-day average. Needs ≥3 nights to be
  /// meaningful; returns null otherwise (so we never compare to noise).
  static double? baselineHours(List<SleepEntry> entries, DateTime today) =>
      _baseline(entries, today, (SleepEntry e) => e.hours);

  /// 14-day average of restingHr, over nights that recorded it (≥3 needed).
  static double? baselineRestingHr(List<SleepEntry> entries, DateTime today) =>
      _baseline(entries, today, (SleepEntry e) => e.restingHr);

  /// 14-day average of HRV, over nights that recorded it (≥3 needed).
  static double? baselineHrv(List<SleepEntry> entries, DateTime today) =>
      _baseline(entries, today, (SleepEntry e) => e.hrv);

  static double? _baseline(List<SleepEntry> entries, DateTime today,
      double? Function(SleepEntry) sel) {
    final List<double> vals = <double>[];
    for (final SleepEntry e in _within(entries, today, 14)) {
      final double? v = sel(e);
      if (v != null && v > 0) {
        vals.add(v);
      }
    }
    if (vals.length < 3) {
      return null;
    }
    return vals.reduce((double a, double b) => a + b) / vals.length;
  }
}

// ───────────────────────────────────────────────────────────────────────
// READINESS — a transparent daily read. It shows its inputs; no black box.
// ───────────────────────────────────────────────────────────────────────

class Readiness {
  final int score; // 0..100
  final String label; // 'Ready' | 'Moderate' | 'Take it easy'
  final List<String> factors; // human-readable contributions
  const Readiness(this.score, this.label, this.factors);
}

/// Combine last night's sleep (vs the user's own baseline), recent run load,
/// and deficit depth into a recovery read. Every deduction is spelled out in
/// [factors] so it's honest, not mysterious. Returns null when there's no
/// sleep to read (the feature is sleep-gated).
Readiness? computeReadiness({
  required double? lastNightHours,
  required double? baselineHours,
  required int runsLast7,
  required int deficit,
  double? restingHr,
  double? baselineRestingHr,
  double? hrv,
  double? baselineHrv,
}) {
  if (lastNightHours == null) {
    return null;
  }
  int score = 100;
  final List<String> factors = <String>[];

  // Sleep vs the user's own norm (falls back to a 7.5h reference).
  final double norm = baselineHours ?? 7.5;
  final double gap = norm - lastNightHours;
  if (gap >= 0.5) {
    final int pen = (gap * 12).round().clamp(0, 45);
    score -= pen;
    factors.add('Slept ${lastNightHours.toStringAsFixed(1)}h vs your '
        '${norm.toStringAsFixed(1)}h norm (−$pen)');
  } else {
    factors.add('Slept ${lastNightHours.toStringAsFixed(1)}h — on par with '
        'your ${norm.toStringAsFixed(1)}h norm');
  }
  // A hard floor: very short nights hurt regardless of baseline.
  if (lastNightHours < 6) {
    score -= 10;
    factors.add('Under 6h is short sleep (−10)');
  }
  // Training load.
  if (runsLast7 >= 4) {
    score -= 10;
    factors.add('$runsLast7 runs in 7 days — high load (−10)');
  }
  // Deficit depth.
  if (deficit >= 700) {
    score -= 10;
    factors.add('Steep ${deficit}-kcal deficit taxes recovery (−10)');
  }
  // Resting heart rate elevated vs your own norm = under-recovered.
  if (restingHr != null && baselineRestingHr != null) {
    final double up = restingHr - baselineRestingHr;
    if (up >= 3) {
      final int pen = (up * 2).round().clamp(0, 15);
      score -= pen;
      factors.add('Resting HR ${restingHr.round()} vs your '
          '${baselineRestingHr.round()} norm (−$pen)');
    }
  }
  // HRV below your own norm = under-recovered.
  if (hrv != null && baselineHrv != null && baselineHrv > 0) {
    final double drop = (baselineHrv - hrv) / baselineHrv;
    if (drop >= 0.10) {
      final int pen = (drop * 40).round().clamp(0, 15);
      score -= pen;
      factors.add('HRV ${hrv.round()}ms below your '
          '${baselineHrv.round()}ms norm (−$pen)');
    }
  }

  score = score.clamp(0, 100);
  final String label =
      score >= 75 ? 'Ready' : (score >= 50 ? 'Moderate' : 'Take it easy');
  return Readiness(score, label, factors);
}

// ───────────────────────────────────────────────────────────────────────
// TRAINER REACTION — a sleep-aware nudge for today's run (null = stay quiet).
// ───────────────────────────────────────────────────────────────────────

String? trainerSleepNote(double? lastNightHours, double? baselineHours) {
  if (lastNightHours == null) {
    return null;
  }
  final double norm = baselineHours ?? 7.5;
  if (lastNightHours < 6 || lastNightHours <= norm - 1.5) {
    return 'Rough night (${lastNightHours.toStringAsFixed(1)}h). Ease into it '
        'or repeat today — no need to force a level-up.';
  }
  if (lastNightHours >= norm) {
    return 'Well rested (${lastNightHours.toStringAsFixed(1)}h) — good day to '
        'push.';
  }
  return null;
}

// ───────────────────────────────────────────────────────────────────────
// SCALE-NOISE EXPLAINER — context for a weight jump after short sleep.
// Returns null unless the jump is real AND sleep was short (so we don't cry
// wolf). [weightDeltaLb] is today − previous weigh-in.
// ───────────────────────────────────────────────────────────────────────

String? scaleNoiseNote(double weightDeltaLb, double? recentSleepHours) {
  if (recentSleepHours == null) {
    return null;
  }
  if (weightDeltaLb >= 0.8 && recentSleepHours < 6) {
    return "You're up ${weightDeltaLb.toStringAsFixed(1)} lb, but only slept "
        "${recentSleepHours.toStringAsFixed(1)}h — short sleep holds water, "
        "so this is likely fluid, not fat.";
  }
  return null;
}

/// A compact sleep summary for the AI-coach digests (empty when no data).
String sleepDigest(List<SleepEntry> entries, DateTime today) {
  final SleepEntry? last = SleepMath.latest(entries);
  if (last == null) {
    return '';
  }
  final double? avg = SleepMath.averageHours(entries, today, 7);
  final StringBuffer b = StringBuffer();
  b.write('Sleep: last night ${last.hours.toStringAsFixed(1)}h');
  if (last.hasStages) {
    b.write(' (deep ${last.deepMin}m, REM ${last.remMin}m)');
  }
  if (avg != null) {
    b.write(', 7-day average ${avg.toStringAsFixed(1)}h');
  }
  b.write('.');
  // Recovery vitals vs the user's own norm, when recorded.
  final List<String> vitals = <String>[];
  if (last.restingHr != null) {
    final double? base = SleepMath.baselineRestingHr(entries, today);
    vitals.add('resting HR ${last.restingHr!.round()}'
        '${base != null ? " (norm ${base.round()})" : ""}');
  }
  if (last.hrv != null) {
    final double? base = SleepMath.baselineHrv(entries, today);
    vitals.add('HRV ${last.hrv!.round()}ms'
        '${base != null ? " (norm ${base.round()})" : ""}');
  }
  if (last.respiratoryRate != null) {
    vitals.add('respiratory rate ${last.respiratoryRate!.toStringAsFixed(1)}/min');
  }
  if (vitals.isNotEmpty) {
    b.write(' Recovery: ${vitals.join(', ')}.');
  }
  return b.toString();
}

List<SleepEntry> decodeSleep(String jsonStr) {
  try {
    final dynamic d = jsonDecode(jsonStr);
    if (d is List) {
      return d
          .whereType<Map<String, dynamic>>()
          .map(SleepEntry.fromJson)
          .toList();
    }
  } catch (_) {}
  return <SleepEntry>[];
}
