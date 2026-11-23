import 'package:health/health.dart';

import 'gymboard_bridge.dart';

// ═══════════════════════════════════════════════════════════════════════
// GYM VITALS — how hard the workout actually was.
//
// Gymboard records what you did and exactly when. It cannot know what your
// heart was doing, because it runs on a TV. The watch can, and Health
// Connect is where a Pixel Watch puts it.
//
// So this asks one question per workout: over this window, what was the
// heart rate and what did it cost. Nothing outside those windows is read,
// and nothing is written anywhere.
//
// Everything is best effort. A workout with no watch data keeps the
// board's own numbers and simply shows no heart rate.
// ═══════════════════════════════════════════════════════════════════════

const List<HealthDataType> _types = <HealthDataType>[
  HealthDataType.HEART_RATE,
  HealthDataType.ACTIVE_ENERGY_BURNED,
];

/// Fills in heart rate and active energy for any workout still missing them.
/// Returns the list unchanged if the watch has nothing to say, so the caller
/// can always use the result.
Future<List<GymboardWorkout>> attachVitals(
    List<GymboardWorkout> workouts) async {
  final List<GymboardWorkout> todo = workouts
      .where((GymboardWorkout w) => !w.hasVitals && w.ms > 0)
      .toList();
  if (todo.isEmpty) return workouts;

  // One query covering every window that needs filling, rather than one
  // round trip per workout. Health Connect is slow and this runs at launch.
  DateTime from = todo.first.at;
  DateTime to = todo.first.endsAt;
  for (final GymboardWorkout w in todo) {
    if (w.at.isBefore(from)) from = w.at;
    if (w.endsAt.isAfter(to)) to = w.endsAt;
  }
  // Health Connect keeps 30 days by default; asking for more is wasted work.
  final DateTime floor =
      DateTime.now().subtract(const Duration(days: 30));
  if (from.isBefore(floor)) from = floor;
  if (!to.isAfter(from)) return workouts;

  List<HealthDataPoint> hr = <HealthDataPoint>[];
  List<HealthDataPoint> cal = <HealthDataPoint>[];
  try {
    final Health health = Health();
    await health.configure();
    final bool granted = await health.requestAuthorization(_types,
        permissions:
            _types.map((_) => HealthDataAccess.READ).toList());
    if (!granted) return workouts;

    try {
      hr = await health.getHealthDataFromTypes(
          startTime: from,
          endTime: to,
          types: <HealthDataType>[HealthDataType.HEART_RATE]);
    } catch (_) {}
    try {
      cal = await health.getHealthDataFromTypes(
          startTime: from,
          endTime: to,
          types: <HealthDataType>[HealthDataType.ACTIVE_ENERGY_BURNED]);
    } catch (_) {}
  } catch (_) {
    return workouts;
  }
  if (hr.isEmpty && cal.isEmpty) return workouts;

  double? _num(HealthDataPoint p) {
    final HealthValue v = p.value;
    return v is NumericHealthValue ? v.numericValue.toDouble() : null;
  }

  // A sample counts if it overlaps the window at all. Requiring it to sit
  // wholly inside drops the long aggregated buckets some sources write,
  // which is most of the energy data on a Pixel Watch.
  bool overlaps(HealthDataPoint p, DateTime a, DateTime b) =>
      p.dateFrom.isBefore(b) && p.dateTo.isAfter(a);

  final List<GymboardWorkout> out = <GymboardWorkout>[];
  for (final GymboardWorkout w in workouts) {
    if (w.hasVitals || w.ms <= 0) {
      out.add(w);
      continue;
    }
    final DateTime a = w.at, b = w.endsAt;

    double sum = 0, peak = 0;
    int n = 0;
    for (final HealthDataPoint p in hr) {
      if (!overlaps(p, a, b)) continue;
      final double? v = _num(p);
      if (v == null || v <= 0) continue;
      sum += v;
      n++;
      if (v > peak) peak = v;
    }

    double energy = 0;
    bool anyEnergy = false;
    for (final HealthDataPoint p in cal) {
      if (!overlaps(p, a, b)) continue;
      final double? v = _num(p);
      if (v == null || v <= 0) continue;
      energy += v;
      anyEnergy = true;
    }

    out.add(n == 0 && !anyEnergy
        ? w
        : w.withVitals(
            avgHr: n > 0 ? sum / n : null,
            maxHr: peak > 0 ? peak : null,
            kcal: anyEnergy ? energy : null,
          ));
  }
  return out;
}
