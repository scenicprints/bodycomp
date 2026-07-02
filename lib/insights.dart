import 'sleep.dart';
import 'trainer.dart';

// ═══════════════════════════════════════════════════════════════════════
// LOCAL INSIGHTS — the "am I getting better or worse?" read.
//
// Everything here is pure and computed from the user's OWN history — no API,
// no network, instant and free. A tapped sleep night or run gets a short
// headline plus a few plain-language notes, each grounded in the user's own
// baselines and trends. Unit-tested; the UI just renders what these return.
// ═══════════════════════════════════════════════════════════════════════

/// A simple, explainable trend read over an oldest→newest numeric series.
/// Compares the mean of the earlier half to the later half — robust to a
/// single noisy point and easy to state in words.
class SeriesTrend {
  final int n; // points used
  final double earlier; // mean of the earlier half
  final double later; // mean of the later half
  const SeriesTrend(this.n, this.earlier, this.later);

  /// Signed change, later − earlier.
  double get delta => later - earlier;
  double get magnitude => delta.abs();
  bool get rising => delta > 0;
}

/// Trend over [series] (oldest→newest). Null when too short to be meaningful
/// (< 4 points) so we never draw a conclusion from noise.
SeriesTrend? trendOf(List<double> series) {
  final List<double> v = series.where((double x) => x.isFinite).toList();
  if (v.length < 4) {
    return null;
  }
  final int h = v.length ~/ 2;
  final List<double> a = v.sublist(0, h);
  final List<double> b = v.sublist(v.length - h);
  double mean(List<double> l) =>
      l.reduce((double x, double y) => x + y) / l.length;
  return SeriesTrend(v.length, mean(a), mean(b));
}

/// One entry's insight: a headline plus a few plain-language notes.
class InsightRead {
  final String headline;
  final List<String> notes;
  const InsightRead(this.headline, this.notes);
}

// ───────────────────────────────────────────────────────────────────────
// SLEEP
// ───────────────────────────────────────────────────────────────────────

List<SleepEntry> _sortedNights(List<SleepEntry> all) {
  final List<SleepEntry> s = List<SleepEntry>.of(all);
  s.sort((SleepEntry a, SleepEntry b) => a.date.compareTo(b.date));
  return s;
}

/// Chronological (oldest→newest) values of a numeric field over the nights up
/// to and including [uptoDate], most recent [days] of them. Nights missing the
/// field are skipped. For sparklines and trends.
List<double> sleepSeries(
    List<SleepEntry> all, String uptoDate, double? Function(SleepEntry) sel,
    {int days = 21}) {
  final List<SleepEntry> s = _sortedNights(all)
      .where((SleepEntry e) => e.date.compareTo(uptoDate) <= 0)
      .toList();
  final List<SleepEntry> window =
      s.length > days ? s.sublist(s.length - days) : s;
  final List<double> out = <double>[];
  for (final SleepEntry e in window) {
    final double? v = sel(e);
    if (v != null && v > 0) {
      out.add(v);
    }
  }
  return out;
}

/// The read for a single night, judged against the user's own norms.
InsightRead sleepNightRead(SleepEntry e, List<SleepEntry> all) {
  final DateTime asOf = DateTime.tryParse(e.date) ?? DateTime.now();
  final List<String> notes = <String>[];

  // Hours vs personal norm.
  final double? norm = SleepMath.baselineHours(all, asOf);
  if (norm != null) {
    final double d = e.hours - norm;
    if (d.abs() < 0.4) {
      notes.add('${e.hours.toStringAsFixed(1)}h — right on your '
          '${norm.toStringAsFixed(1)}h norm.');
    } else if (d > 0) {
      notes.add('${e.hours.toStringAsFixed(1)}h — ${d.toStringAsFixed(1)}h '
          'above your ${norm.toStringAsFixed(1)}h norm.');
    } else {
      notes.add('${e.hours.toStringAsFixed(1)}h — ${(-d).toStringAsFixed(1)}h '
          'below your ${norm.toStringAsFixed(1)}h norm.');
    }
  }

  // Resting HR vs norm (lower is better).
  if (e.restingHr != null) {
    final double? base = SleepMath.baselineRestingHr(all, asOf);
    if (base != null) {
      final double d = e.restingHr! - base;
      if (d <= -2) {
        notes.add('Resting HR ${e.restingHr!.round()} — ${(-d).round()} below '
            'your ${base.round()} norm (well recovered).');
      } else if (d >= 2) {
        notes.add('Resting HR ${e.restingHr!.round()} — ${d.round()} above '
            'your ${base.round()} norm (may be run down).');
      } else {
        notes.add(
            'Resting HR ${e.restingHr!.round()} — on your ${base.round()} norm.');
      }
    }
  }

  // HRV vs norm (higher is better).
  if (e.hrv != null) {
    final double? base = SleepMath.baselineHrv(all, asOf);
    if (base != null && base > 0) {
      final double pct = (e.hrv! - base) / base;
      if (pct >= 0.08) {
        notes.add('HRV ${e.hrv!.round()}ms — above your ${base.round()}ms norm '
            '(good recovery).');
      } else if (pct <= -0.08) {
        notes.add('HRV ${e.hrv!.round()}ms — below your ${base.round()}ms norm '
            '(under-recovered).');
      } else {
        notes.add('HRV ${e.hrv!.round()}ms — on your ${base.round()}ms norm.');
      }
    }
  }

  // Deep-sleep share of the night.
  if (e.hasStages) {
    final int deep = e.deepMin ?? 0;
    final int total = (e.deepMin ?? 0) + (e.remMin ?? 0) + (e.lightMin ?? 0);
    if (total > 0) {
      notes.add('Deep sleep ${(deep * 100 / total).round()}% of the night '
          '(${deep}m).');
    }
  }

  // Recovery direction from the resting-HR trend (lower = improving).
  final SeriesTrend? rt =
      trendOf(sleepSeries(all, e.date, (SleepEntry x) => x.restingHr));
  if (rt != null && rt.magnitude >= 1.0) {
    notes.add(rt.delta < 0
        ? 'Resting HR trending down across recent nights — recovery improving.'
        : 'Resting HR creeping up across recent nights — watch your load.');
  }

  return InsightRead(_sleepHeadline(e, all, asOf, norm), notes);
}

String _sleepHeadline(
    SleepEntry e, List<SleepEntry> all, DateTime asOf, double? norm) {
  // Elevated resting HR is the strongest "run down" signal.
  if (e.restingHr != null) {
    final double? base = SleepMath.baselineRestingHr(all, asOf);
    if (base != null && e.restingHr! - base >= 4) {
      return 'You may be run down';
    }
  }
  if (norm != null && e.hours >= norm + 1) {
    return 'A strong night';
  }
  if (e.hours < 6) {
    return 'Short night';
  }
  if (norm != null && e.hours <= norm - 1) {
    return 'Below your norm';
  }
  return 'A typical night';
}

// ───────────────────────────────────────────────────────────────────────
// RUNS
// ───────────────────────────────────────────────────────────────────────

/// Average pace (sec/km) over runs at [level] that have a distance, excluding
/// [exceptId]. Null when there are none to compare against.
double? avgPaceSecPerKmAtLevel(List<RunRecord> runs, int level,
    {String? exceptId}) {
  final List<double> paces = <double>[];
  for (final RunRecord r in runs) {
    if (r.level == level && r.id != exceptId && r.distanceKm > 0) {
      paces.add(r.paceSecPerKm);
    }
  }
  if (paces.isEmpty) {
    return null;
  }
  return paces.reduce((double a, double b) => a + b) / paces.length;
}

/// Chronological (oldest→newest) pace series (sec/km) over runs with a
/// distance, most recent [last] of them.
List<double> runPaceSeries(List<RunRecord> runs, {int last = 12}) {
  final List<RunRecord> s =
      runs.where((RunRecord r) => r.distanceKm > 0).toList()
        ..sort((RunRecord a, RunRecord b) => a.date.compareTo(b.date));
  final List<RunRecord> w = s.length > last ? s.sublist(s.length - last) : s;
  return w.map((RunRecord r) => r.paceSecPerKm).toList();
}

/// Format a pace delta in seconds as "18s" or "1:05".
String paceDeltaLabel(int seconds) {
  final int s = seconds.abs();
  if (s < 60) {
    return '${s}s';
  }
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The read for a single run, judged against the user's own runs and vitals.
/// [restingHr] is the user's resting-HR baseline, when known.
InsightRead runRead(RunRecord r, List<RunRecord> all, {double? restingHr}) {
  final List<String> notes = <String>[];

  // Pace vs your average at this level.
  if (r.distanceKm > 0 && r.level > 0) {
    final double? avg = avgPaceSecPerKmAtLevel(all, r.level, exceptId: r.id);
    if (avg != null) {
      final int dPerMi = ((r.paceSecPerKm - avg) * 1.609344).round();
      if (dPerMi.abs() >= 5) {
        notes.add(dPerMi < 0
            ? '${paceDeltaLabel(dPerMi)}/mi faster than your Level ${r.level} '
                'average.'
            : '${paceDeltaLabel(dPerMi)}/mi slower than your Level ${r.level} '
                'average.');
      } else {
        notes.add('Right on your Level ${r.level} average pace.');
      }
    }
  }

  // Effort from HR reserve vs your resting HR.
  if (r.avgHr != null && restingHr != null && restingHr > 0) {
    final double reserve = r.avgHr! - restingHr;
    final String label =
        reserve <= 70 ? 'controlled' : (reserve >= 110 ? 'a grind' : 'solid');
    notes.add('${r.avgHr!.round()} bpm — ${reserve.round()} over your '
        '${restingHr.round()} resting. That\'s $label.');
  }

  // Pace trend across recent runs (lower sec/km = faster = improving).
  final SeriesTrend? pt = trendOf(runPaceSeries(all));
  if (pt != null) {
    final int dPerMi = (pt.delta * 1.609344).round();
    if (dPerMi.abs() >= 5) {
      notes.add(dPerMi < 0
          ? 'Your pace is trending faster across recent runs — fitness is '
              'coming.'
          : 'Your pace has drifted slower across recent runs.');
    }
  }

  return InsightRead(_runHeadline(r, all, restingHr), notes);
}

String _runHeadline(RunRecord r, List<RunRecord> all, double? restingHr) {
  if (!r.completed) {
    return 'Partial run';
  }
  // Fastest yet at this level?
  if (r.distanceKm > 0 && r.level > 0) {
    final List<RunRecord> others = all
        .where((RunRecord x) =>
            x.level == r.level && x.id != r.id && x.distanceKm > 0)
        .toList();
    if (others.isNotEmpty &&
        others.every((RunRecord x) => r.paceSecPerKm <= x.paceSecPerKm)) {
      return 'Fastest at Level ${r.level}';
    }
  }
  if (r.avgHr != null && restingHr != null && restingHr > 0) {
    final double reserve = r.avgHr! - restingHr;
    if (reserve <= 70) {
      return 'Controlled effort';
    }
    if (reserve >= 110) {
      return 'A hard grind';
    }
    return 'A solid run';
  }
  return 'Run logged';
}
