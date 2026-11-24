import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:health/health.dart';

import 'food.dart';
import 'main.dart';

// ═══════════════════════════════════════════════════════════════════════
// NUTRITION SYNC — what you ate, handed to Health Connect.
//
// BodyComp is the only place food gets logged, but it is not the only app
// that wants to know. Workouts, on the same phone, reads Health Connect
// for its own ledger and would like calories and protein per day without
// talking to this app directly. Health Connect is the shared mailbox.
//
// So every day with food becomes one nutrition record: local midnight to
// one second before the next, carrying the day's totals. Not one record
// per entry, because Workouts wants the day and every edit here would
// otherwise mean hunting down the one record it changed. The record is
// replaced whole: delete whatever this app wrote in that window, then
// write the fresh total. Health Connect only lets an app delete its own
// records, so nothing another app logged is touched.
//
// A small ledger in AppStorage remembers what was last written per date,
// so a day whose totals have not moved is left alone. Health Connect is
// slow and this runs on every save.
//
// Everything here is best effort and silent. No Health Connect, no
// permission, a write that fails: the food log is unaffected and the
// caller never hears about it.
//
// The pure half (which days need writing, what goes in the record) is
// plain Dart so it can be tested; the bottom of the file is the only part
// that touches the plugin.
// ═══════════════════════════════════════════════════════════════════════

/// AppStorage pref holding the per-date ledger of what was last written.
const String kNutritionSyncedPref = 'nutritionSynced';

/// Health Connect keeps 30 days by default and nobody edits food older
/// than this. Older dates are neither written nor remembered.
const int kNutritionSyncWindowDays = 60;

/// What a nutrition record would carry for one date, or [isEmpty] when
/// the day no longer has food and the old record should simply go.
class NutritionDay {
  final String date; // 'YYYY-MM-DD'
  final double calories;
  final double protein;
  final double fat;
  final double carbs;
  final bool isEmpty;

  const NutritionDay(
      this.date, this.calories, this.protein, this.fat, this.carbs,
      {this.isEmpty = false});

  /// The totals as one string, rounded so float noise from re-adding the
  /// same entries does not count as a change.
  String get stamp => nutritionStamp(calories, protein, fat, carbs);

  /// Local midnight of the day.
  DateTime get start {
    final List<int> p = date.split('-').map(int.parse).toList();
    return DateTime(p[0], p[1], p[2]);
  }

  /// The last second of the day, so the record sits inside one local date.
  DateTime get end {
    final DateTime s = start;
    return DateTime(s.year, s.month, s.day, 23, 59, 59);
  }
}

/// The ledger value for a set of totals.
String nutritionStamp(double cal, double p, double f, double c) =>
    '${cal.round()}|${p.round()}|${f.round()}|${c.round()}';

/// A day's totals as the record it would become.
NutritionDay nutritionDayFor(List<FoodEntry> foods, String date) {
  final DayTotals t = FoodMath.totals(foods, date);
  return NutritionDay(date, t.calories, t.protein, t.fat, t.carbs);
}

/// First date (inclusive) still inside the sync window. Counted in calendar
/// days rather than a Duration, so a clock change in between cannot shift
/// it by an hour and land on the wrong date.
String nutritionWindowFloor(DateTime now,
        {int days = kNutritionSyncWindowDays}) =>
    formatDate(DateTime(now.year, now.month, now.day - days));

/// Which dates need a trip to Health Connect, and what to write for each.
///
/// Every date with food inside the window is a candidate, or only
/// [onlyDates] when given. A date whose stamp matches [written] is
/// skipped. A date in [onlyDates] with no food left but a stamp on record
/// comes back [NutritionDay.isEmpty], meaning delete only.
List<NutritionDay> nutritionDaysToSync(List<FoodEntry> foods,
    {Set<String>? onlyDates,
    required Map<String, String> written,
    required DateTime now}) {
  final String floor = nutritionWindowFloor(now);
  final Set<String> dates = <String>{};
  if (onlyDates != null) {
    dates.addAll(onlyDates);
  } else {
    for (final FoodEntry e in foods) {
      dates.add(e.date);
    }
  }
  final List<NutritionDay> out = <NutritionDay>[];
  for (final String d in dates.toList()..sort()) {
    if (d.compareTo(floor) < 0) continue;
    if (FoodMath.forDate(foods, d).isEmpty) {
      if (written.containsKey(d)) {
        out.add(NutritionDay(d, 0, 0, 0, 0, isEmpty: true));
      }
      continue;
    }
    final NutritionDay day = nutritionDayFor(foods, d);
    if (written[d] == day.stamp) continue;
    out.add(day);
  }
  return out;
}

/// Dates whose totals differ between two versions of the food log: what a
/// save should hand to [syncNutritionToHealth] as `onlyDates`.
Set<String> changedNutritionDates(
    List<FoodEntry> before, List<FoodEntry> after) {
  final Set<String> dates = <String>{
    ...before.map((FoodEntry e) => e.date),
    ...after.map((FoodEntry e) => e.date),
  };
  final Set<String> out = <String>{};
  for (final String d in dates) {
    final bool hadBefore = FoodMath.forDate(before, d).isNotEmpty;
    final bool hasAfter = FoodMath.forDate(after, d).isNotEmpty;
    if (hadBefore != hasAfter) {
      out.add(d);
      continue;
    }
    if (hasAfter &&
        nutritionDayFor(before, d).stamp != nutritionDayFor(after, d).stamp) {
      out.add(d);
    }
  }
  return out;
}

/// The ledger as stored: a JSON object of date → stamp. Anything
/// unreadable is treated as an empty ledger, which only costs a rewrite.
Map<String, String> decodeNutritionLedger(String raw) {
  if (raw.isEmpty) return <String, String>{};
  try {
    final dynamic d = jsonDecode(raw);
    if (d is! Map) return <String, String>{};
    final Map<String, String> out = <String, String>{};
    d.forEach((dynamic k, dynamic v) {
      if (k is String && v is String) out[k] = v;
    });
    return out;
  } catch (_) {
    return <String, String>{};
  }
}

/// The ledger for storage, dropping dates that have left the window so it
/// never grows past a couple of months.
String encodeNutritionLedger(Map<String, String> ledger, DateTime now) {
  final String floor = nutritionWindowFloor(now);
  final Map<String, String> kept = <String, String>{};
  for (final String d in ledger.keys.toList()..sort()) {
    if (d.compareTo(floor) >= 0) kept[d] = ledger[d]!;
  }
  return jsonEncode(kept);
}

// ─── The impure half ──────────────────────────────────────────────────

const List<HealthDataType> _types = <HealthDataType>[
  HealthDataType.NUTRITION,
];

// Both: the write is the point, and deleting the old record needs read.
const List<HealthDataAccess> _access = <HealthDataAccess>[
  HealthDataAccess.READ_WRITE,
];

/// Writes each day's food totals to Health Connect as one nutrition record,
/// for every date with food (or only [onlyDates]) inside the window whose
/// totals changed since the last write. Never throws; says what it did.
Future<NutritionSyncResult> syncNutritionToHealth(List<FoodEntry> foods,
    {Set<String>? onlyDates}) async {
  if (!Platform.isAndroid) {
    return const NutritionSyncResult(NutritionSyncOutcome.notAndroid);
  }
  try {
    final DateTime now = DateTime.now();
    final Map<String, String> written =
        decodeNutritionLedger(AppStorage.getPref(kNutritionSyncedPref, ''));
    final List<NutritionDay> todo = nutritionDaysToSync(foods,
        onlyDates: onlyDates, written: written, now: now);
    if (todo.isEmpty) {
      return NutritionSyncResult(NutritionSyncOutcome.upToDate,
          ledgerDays: written.length);
    }

    final Health health = Health();
    await health.configure();
    if (!await health.isHealthConnectAvailable()) {
      return const NutritionSyncResult(NutritionSyncOutcome.unavailable);
    }
    // Only ask when not already granted, so a refusal is not nagged about
    // on every save.
    bool granted =
        await health.hasPermissions(_types, permissions: _access) == true;
    if (!granted) {
      granted = await health.requestAuthorization(_types, permissions: _access);
    }
    if (!granted) {
      return const NutritionSyncResult(NutritionSyncOutcome.denied);
    }

    bool changed = false;
    int wrote = 0;
    int failed = 0;
    for (final NutritionDay day in todo) {
      try {
        // Replace whole: whatever this app wrote in the window goes first,
        // so re-syncing a day never stacks a second record on the first.
        await health.delete(
            type: HealthDataType.NUTRITION,
            startTime: day.start,
            endTime: day.end);
        if (day.isEmpty) {
          written.remove(day.date);
          changed = true;
          continue;
        }
        final bool ok = await health.writeMeal(
          mealType: MealType.UNKNOWN,
          startTime: day.start,
          endTime: day.end,
          name: 'BodyComp day total',
          caloriesConsumed: day.calories,
          protein: day.protein,
          carbohydrates: day.carbs,
          fatTotal: day.fat,
          recordingMethod: RecordingMethod.manual,
        );
        if (!ok) {
          failed++;
          continue;
        }
        written[day.date] = day.stamp;
        wrote++;
        changed = true;
      } catch (_) {
        // This day stays unstamped and is tried again next save.
        failed++;
      }
    }
    if (changed) {
      AppStorage.savePref(
          kNutritionSyncedPref, encodeNutritionLedger(written, now));
    }
    return NutritionSyncResult(
        failed > 0 && wrote == 0
            ? NutritionSyncOutcome.failed
            : NutritionSyncOutcome.wrote,
        wrote: wrote,
        failed: failed,
        ledgerDays: written.length);
  } catch (e) {
    // No Health Connect, no permission, a plugin error: the log is fine.
    return NutritionSyncResult(NutritionSyncOutcome.failed, error: '$e');
  }
}

/// What a sync did, for the Settings card. Callers that save food ignore it.
enum NutritionSyncOutcome {
  notAndroid,
  unavailable,
  denied,
  upToDate,
  wrote,
  failed,
}

class NutritionSyncResult {
  final NutritionSyncOutcome outcome;
  final int wrote;
  final int failed;
  /// Days Health Connect currently holds a record for, per the ledger.
  final int ledgerDays;
  final String? error;
  const NutritionSyncResult(this.outcome,
      {this.wrote = 0, this.failed = 0, this.ledgerDays = 0, this.error});

  /// One line for the user.
  String get message {
    switch (outcome) {
      case NutritionSyncOutcome.notAndroid:
        return 'Health Connect is Android only.';
      case NutritionSyncOutcome.unavailable:
        return 'Health Connect is not available on this phone.';
      case NutritionSyncOutcome.denied:
        return 'Nutrition permission not granted. Allow BodyComp to write '
            'nutrition in Health Connect, then sync again.';
      case NutritionSyncOutcome.upToDate:
        return 'Up to date: $ledgerDays day${ledgerDays == 1 ? '' : 's'} in '
            'Health Connect.';
      case NutritionSyncOutcome.wrote:
        return 'Wrote $wrote day${wrote == 1 ? '' : 's'}'
            '${failed > 0 ? ', $failed failed' : ''}. '
            '$ledgerDays day${ledgerDays == 1 ? '' : 's'} in Health Connect.';
      case NutritionSyncOutcome.failed:
        return 'Sync failed${error != null ? ': $error' : ''}.';
    }
  }
}

/// Settings card: where the food log stands in Health Connect, and a button
/// to push the whole window now. Self-contained so Settings need not be
/// handed the food list; it reads the saved log directly.
class NutritionSyncCard extends StatefulWidget {
  final Color accent;
  const NutritionSyncCard({super.key, required this.accent});
  @override
  State<NutritionSyncCard> createState() => _NutritionSyncCardState();
}

class _NutritionSyncCardState extends State<NutritionSyncCard> {
  bool _busy = false;
  String? _msg;

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    final NutritionSyncResult r =
        await syncNutritionToHealth(AppStorage.getFoods());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = r.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final int days =
        decodeNutritionLedger(AppStorage.getPref(kNutritionSyncedPref, ''))
            .length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Icon(Icons.sync_rounded, size: 15, color: widget.accent),
          const SizedBox(width: 6),
          Text('HEALTH CONNECT',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        const Text('Food log to Health Connect',
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFFDDDDDD))),
        Text(
            'Each day\'s calories, protein, carbs and fat go to Health Connect '
            'as one record, so Workouts can read them. Syncs on every save; '
            '$days day${days == 1 ? '' : 's'} written so far.',
            style:
                TextStyle(fontSize: 11, color: Colors.grey[600], height: 1.35)),
        const SizedBox(height: 10),
        Row(children: <Widget>[
          TextButton(
              onPressed: _busy ? null : _sync,
              child: Text(_busy ? 'Syncing…' : 'Sync the last 60 days',
                  style: TextStyle(color: widget.accent))),
        ]),
        if (_msg != null)
          Text(_msg!,
              style: TextStyle(
                  fontSize: 11, color: Colors.grey[400], height: 1.35)),
      ]),
    );
  }
}
