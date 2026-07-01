import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPicker;
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:health/health.dart';
import 'updater.dart';
import 'food.dart';
import 'custom_foods.dart';
import 'trainer.dart';
import 'sleep.dart';
import 'advisor.dart';

// ═══════════════════════════════════════════════════════════════════════
// DATA MODELS
// ═══════════════════════════════════════════════════════════════════════

class DailyLog {
  final String date;
  final double weight;
  final double bf;
  final int calories;

  DailyLog(
      {required this.date,
      required this.weight,
      required this.bf,
      this.calories = 0});

  double get lbm => weight * (1 - bf);
  double get fatMass => weight * bf;

  Map<String, dynamic> toJson() {
    return {'date': date, 'weight': weight, 'bf': bf, 'calories': calories};
  }

  factory DailyLog.fromJson(Map<String, dynamic> j) {
    return DailyLog(
      date: j['date'] as String,
      weight: (j['weight'] as num).toDouble(),
      bf: (j['bf'] as num).toDouble(),
      calories: (j['calories'] as num?)?.toInt() ?? 0,
    );
  }
}

class UserCalibration {
  final double startWeight;
  final double startBf;
  final double targetBf;
  final double activityMult;
  final int deficit;
  // Macro-target overrides (null = auto-derive). In grams/day.
  final double? proteinTarget;
  final double? fatTarget;
  final double? carbTarget;
  final double? fiberTarget;
  // AI coach model (Settings-selectable).
  final String advisorModel;

  UserCalibration({
    required this.startWeight,
    required this.startBf,
    required this.targetBf,
    this.activityMult = 1.4,
    this.deficit = 500,
    this.proteinTarget,
    this.fatTarget,
    this.carbTarget,
    this.fiberTarget,
    this.advisorModel = kDefaultAdvisorModel,
  });

  double get startLbm => startWeight * (1 - startBf);
  double get startFatMass => startWeight * startBf;

  UserCalibration copyWith({
    double? targetBf,
    double? activityMult,
    int? deficit,
    Object? proteinTarget = _unset,
    Object? fatTarget = _unset,
    Object? carbTarget = _unset,
    Object? fiberTarget = _unset,
    String? advisorModel,
  }) {
    return UserCalibration(
      startWeight: startWeight,
      startBf: startBf,
      targetBf: targetBf ?? this.targetBf,
      activityMult: activityMult ?? this.activityMult,
      deficit: deficit ?? this.deficit,
      advisorModel: advisorModel ?? this.advisorModel,
      proteinTarget: proteinTarget == _unset
          ? this.proteinTarget
          : (proteinTarget as num?)?.toDouble(),
      fatTarget:
          fatTarget == _unset ? this.fatTarget : (fatTarget as num?)?.toDouble(),
      carbTarget: carbTarget == _unset
          ? this.carbTarget
          : (carbTarget as num?)?.toDouble(),
      fiberTarget: fiberTarget == _unset
          ? this.fiberTarget
          : (fiberTarget as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'startWeight': startWeight,
      'startBf': startBf,
      'targetBf': targetBf,
      'activityMult': activityMult,
      'deficit': deficit,
      if (proteinTarget != null) 'proteinTarget': proteinTarget,
      if (fatTarget != null) 'fatTarget': fatTarget,
      if (carbTarget != null) 'carbTarget': carbTarget,
      if (fiberTarget != null) 'fiberTarget': fiberTarget,
      'advisorModel': advisorModel,
    };
  }

  factory UserCalibration.fromJson(Map<String, dynamic> j) {
    return UserCalibration(
      startWeight: (j['startWeight'] as num).toDouble(),
      startBf: (j['startBf'] as num).toDouble(),
      targetBf: (j['targetBf'] as num).toDouble(),
      activityMult: (j['activityMult'] as num?)?.toDouble() ?? 1.4,
      deficit: (j['deficit'] as num?)?.toInt() ?? 500,
      proteinTarget: (j['proteinTarget'] as num?)?.toDouble(),
      fatTarget: (j['fatTarget'] as num?)?.toDouble(),
      carbTarget: (j['carbTarget'] as num?)?.toDouble(),
      fiberTarget: (j['fiberTarget'] as num?)?.toDouble(),
      advisorModel: (j['advisorModel'] as String?) ?? kDefaultAdvisorModel,
    );
  }
}

const Object _unset = Object();

// ═══════════════════════════════════════════════════════════════════════
// MATH ENGINE
// ═══════════════════════════════════════════════════════════════════════

class MathEngine {
  static double leanBodyMass(double w, double bf) {
    return w * (1 - bf);
  }

  static double dynamicTargetWeight(double lbm, double targetBf) {
    return lbm / (1 - targetBf);
  }

  static double bmr(double lbmLbs) {
    return 370 + 21.6 * (lbmLbs / 2.2046);
  }

  static double baselineTdee(double lbmLbs, double mult) {
    return bmr(lbmLbs) * mult;
  }

  /// Energy-balance back-calculation over days with KNOWN intake.
  /// Caller decides which days are known (food-logged, fasted, or manual) —
  /// a 0-calorie fasted day is valid here, an unlogged day must be excluded.
  static double? adaptiveTdeeFrom(List<DailyLog> intakeDays) {
    if (intakeDays.length < 14) {
      return null;
    }
    final List<DailyLog> recent =
        intakeDays.sublist(intakeDays.length - 14);
    final int totalCal =
        recent.fold<int>(0, (int s, DailyLog l) => s + l.calories);
    final double fatLost = recent.first.fatMass - recent.last.fatMass;
    return (totalCal + fatLost * 3500) / 14;
  }

  /// Backward-compatible: treats calories > 0 as the "known intake" signal.
  static double? adaptiveTdee(List<DailyLog> logs) =>
      adaptiveTdeeFrom(logs.where((DailyLog l) => l.calories > 0).toList());

  /// Lean body mass averaged over the most recent [window] logs, so the
  /// baseline TDEE rides a smoothed trend instead of a single noisy weigh-in.
  static double rollingLbm(List<DailyLog> logs, {int window = 7}) {
    if (logs.isEmpty) {
      return 0;
    }
    final int start = max(0, logs.length - window);
    final List<DailyLog> slice = logs.sublist(start);
    return slice.fold<double>(0, (double s, DailyLog l) => s + l.lbm) /
        slice.length;
  }

  /// Resolves each weigh-in day's effective intake:
  ///  • food-logged day  → that date's food total
  ///  • fasted day       → 0 kcal (an intentional fast IS known intake)
  ///  • manual cal > 0   → the typed number (legacy)
  ///  • otherwise        → excluded (we genuinely don't know)
  static List<DailyLog> resolveIntake(List<DailyLog> logs,
      Map<String, double> caloriesByDate, Set<String> fastedDates) {
    final List<DailyLog> out = <DailyLog>[];
    for (final DailyLog l in logs) {
      final double? f = caloriesByDate[l.date];
      if (f != null && f > 0) {
        out.add(DailyLog(
            date: l.date, weight: l.weight, bf: l.bf, calories: f.round()));
      } else if (fastedDates.contains(l.date)) {
        out.add(DailyLog(date: l.date, weight: l.weight, bf: l.bf, calories: 0));
      } else if (l.calories > 0) {
        out.add(l);
      }
    }
    return out;
  }

  static double activeTdee(List<DailyLog> logs, double mult,
      {Map<String, double>? caloriesByDate, Set<String>? fastedDates}) {
    final List<DailyLog> intake = resolveIntake(
        logs, caloriesByDate ?? <String, double>{},
        fastedDates ?? <String>{});
    final double? adaptive = adaptiveTdeeFrom(intake);
    if (adaptive != null) {
      return adaptive;
    }
    if (logs.isEmpty) {
      return 0;
    }
    return baselineTdee(rollingLbm(logs), mult);
  }

  static double rollingAvg(List<DailyLog> logs, int idx, {int window = 7}) {
    final int start = max(0, idx - window + 1);
    final List<DailyLog> slice = logs.sublist(start, idx + 1);
    return slice.fold<double>(0, (double s, DailyLog l) => s + l.weight) /
        slice.length;
  }

  static double progress(double startBf, double currentBf, double targetBf) {
    if (startBf <= targetBf) {
      return 1.0;
    }
    return ((startBf - currentBf) / (startBf - targetBf)).clamp(0.0, 1.0);
  }

  static int phase(double p) {
    if (p >= 0.75) {
      return 3;
    }
    if (p >= 0.50) {
      return 2;
    }
    if (p >= 0.25) {
      return 1;
    }
    return 0;
  }

  static bool isPlateau(List<DailyLog> logs) {
    if (logs.length < 17) {
      return false;
    }
    final List<DailyLog> r10 = logs.sublist(logs.length - 10);
    final List<DailyLog> o7 = logs.sublist(logs.length - 17, logs.length - 10);
    final double avgR =
        r10.fold<double>(0, (double s, DailyLog l) => s + l.weight) / 10;
    final double avgO =
        o7.fold<double>(0, (double s, DailyLog l) => s + l.weight) / 7;
    return (avgR - avgO).abs() < 0.5;
  }

  static int? daysToGoal(List<DailyLog> logs, double targetBf) {
    if (logs.length < 7) {
      return null;
    }
    final int window = min(30, logs.length);
    final List<DailyLog> slice = logs.sublist(logs.length - window);
    final double fatLost = slice.first.fatMass - slice.last.fatMass;
    if (fatLost <= 0) {
      return null;
    }
    final double fatPerDay = fatLost / window.toDouble();
    final DailyLog current = logs.last;
    final double targetFat = current.lbm * (targetBf / (1 - targetBf));
    final double fatRemaining = current.fatMass - targetFat;
    if (fatRemaining <= 0) {
      return 0;
    }
    return (fatRemaining / fatPerDay).ceil();
  }

  static DateTime? goalDate(List<DailyLog> logs, double targetBf) {
    final int? days = daysToGoal(logs, targetBf);
    if (days == null) {
      return null;
    }
    return DateTime.now().add(Duration(days: days));
  }
}

// ═══════════════════════════════════════════════════════════════════════
// STORAGE
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
// MACRO TARGETS  (auto-derived, overridable in Settings)
// ═══════════════════════════════════════════════════════════════════════

class MacroTargets {
  final double calories;
  final double protein;
  final double fat;
  final double carbs;
  final double fiber;
  const MacroTargets(
      {required this.calories,
      required this.protein,
      required this.fat,
      required this.carbs,
      required this.fiber});

  static MacroTargets compute(UserCalibration cal, List<DailyLog> logs,
      List<FoodEntry> foods, Set<String> fasted) {
    final double tdee = logs.isEmpty
        ? 0
        : MathEngine.activeTdee(logs, cal.activityMult,
            caloriesByDate: FoodMath.caloriesByDate(foods), fastedDates: fasted);
    final double calTarget = tdee > 0 ? tdee - cal.deficit : 0;
    final double lbm = logs.isNotEmpty ? logs.last.lbm : cal.startLbm;
    final double bw = logs.isNotEmpty ? logs.last.weight : cal.startWeight;
    final double protein = cal.proteinTarget ?? lbm * 1.0; // 1 g / lb LBM
    final double fat = cal.fatTarget ?? bw * 0.3; // 0.3 g / lb body weight
    final double carbs = cal.carbTarget ??
        max(0.0, (calTarget - protein * 4 - fat * 9) / 4);
    final double fiber =
        cal.fiberTarget ?? (calTarget > 0 ? calTarget / 1000 * 14 : 25);
    return MacroTargets(
        calories: calTarget,
        protein: protein,
        fat: fat,
        carbs: carbs,
        fiber: fiber);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ADVISOR DIGEST  — the local facts we send to the AI coach
// ═══════════════════════════════════════════════════════════════════════

class AdvisorDigest {
  static String build(UserCalibration cal, List<DailyLog> logs,
      List<FoodEntry> foods, Set<String> fasted, String kind,
      {List<SleepEntry> sleep = const <SleepEntry>[],
      List<RunRecord> runs = const <RunRecord>[],
      int trainerLevel = 0}) {
    final DateTime now = DateTime.now();
    final String today = formatDate(now);
    final MacroTargets t = MacroTargets.compute(cal, logs, foods, fasted);
    final Map<String, double> byDateCal = FoodMath.caloriesByDate(foods);
    final Map<String, DailyLog> logByDate = <String, DailyLog>{
      for (final DailyLog l in logs) l.date: l
    };
    final double tdee = logs.isEmpty
        ? 0
        : MathEngine.activeTdee(logs, cal.activityMult,
            caloriesByDate: byDateCal, fastedDates: fasted);

    final StringBuffer sb = StringBuffer();
    sb.writeln('DATE: $today');
    sb.writeln(
        'GOAL: start body-fat ${(cal.startBf * 100).toStringAsFixed(1)}% → target ${(cal.targetBf * 100).toStringAsFixed(1)}%; intended daily deficit ${cal.deficit} cal.');
    sb.writeln(
        'DAILY TARGETS: ${t.calories.round()} cal, protein ${t.protein.round()} g, fat ${t.fat.round()} g, carbs ${t.carbs.round()} g, fiber ${t.fiber.round()} g.');
    if (tdee > 0) {
      sb.writeln('ESTIMATED TDEE (maintenance): ${tdee.round()} cal.');
    }

    if (logs.isNotEmpty) {
      final DailyLog last = logs.last;
      sb.writeln(
          'LATEST WEIGH-IN (${last.date}): ${last.weight.toStringAsFixed(1)} lb, ${(last.bf * 100).toStringAsFixed(1)}% BF, lean mass ${last.lbm.toStringAsFixed(1)} lb.');
      double? change(int days) {
        final String cutoff = formatDate(now.subtract(Duration(days: days)));
        final List<DailyLog> older =
            logs.where((DailyLog l) => l.date.compareTo(cutoff) <= 0).toList();
        return older.isEmpty ? null : last.weight - older.last.weight;
      }

      final double? c14 = change(14), c30 = change(30);
      if (c14 != null) {
        sb.writeln(
            'WEIGHT CHANGE last ~14d: ${c14 >= 0 ? '+' : ''}${c14.toStringAsFixed(1)} lb.');
      }
      if (c30 != null) {
        sb.writeln(
            'WEIGHT CHANGE last ~30d: ${c30 >= 0 ? '+' : ''}${c30.toStringAsFixed(1)} lb.');
      }
      final DateTime? goal = MathEngine.goalDate(logs, cal.targetBf);
      if (goal != null) {
        sb.writeln(
            'PROJECTED GOAL DATE at current pace: ${monthName(goal.month)} ${goal.day}, ${goal.year}.');
      }
      if (MathEngine.isPlateau(logs)) {
        sb.writeln('NOTE: rolling weight average has plateaued (~10 days).');
      }
    }

    // Adherence + deficit-vs-actual over the detail window.
    final int detailDays = kind == 'weekly' ? 7 : 14;
    int eaten = 0;
    double sumCal = 0, sumP = 0, sumF = 0, sumC = 0, sumFiber = 0;
    for (int i = 0; i < detailDays; i++) {
      final String d = formatDate(now.subtract(Duration(days: i)));
      if ((byDateCal[d] ?? 0) > 0) {
        final DayTotals dt = FoodMath.totals(foods, d);
        eaten++;
        sumCal += dt.calories;
        sumP += dt.protein;
        sumF += dt.fat;
        sumC += dt.carbs;
        sumFiber += dt.nutrients['fiber'] ?? 0;
      }
    }
    if (eaten > 0) {
      final double avgCal = sumCal / eaten;
      sb.writeln(
          '\nLAST $detailDays DAYS — logged $eaten day(s); averages: ${avgCal.round()} cal, protein ${(sumP / eaten).round()} g, fat ${(sumF / eaten).round()} g, carbs ${(sumC / eaten).round()} g, fiber ${(sumFiber / eaten).round()} g.');
      if (tdee > 0) {
        final double dailyDeficit = tdee - avgCal;
        sb.writeln(
            'AVERAGE ACTUAL DEFICIT: ${dailyDeficit.round()} cal/day (predicts ~${(dailyDeficit * 7 / 3500).toStringAsFixed(1)} lb/week of fat).');
      }
    }

    sb.writeln('\nPER-DAY DETAIL (oldest to newest):');
    for (int i = detailDays - 1; i >= 0; i--) {
      final String d = formatDate(now.subtract(Duration(days: i)));
      final DailyLog? log = logByDate[d];
      final bool hasFood = (byDateCal[d] ?? 0) > 0;
      final bool isFast = fasted.contains(d);
      if (log == null && !hasFood && !isFast) {
        continue;
      }
      final List<String> parts = <String>[d];
      if (log != null) {
        parts.add(
            '${log.weight.toStringAsFixed(1)}lb/${(log.bf * 100).toStringAsFixed(1)}%');
      }
      if (hasFood) {
        final DayTotals dt = FoodMath.totals(foods, d);
        parts.add(
            '${dt.calories.round()}cal P${dt.protein.round()} F${dt.fat.round()} C${dt.carbs.round()} fib${(dt.nutrients['fiber'] ?? 0).round()}');
        final List<String> names = FoodMath.forDate(foods, d)
            .map((FoodEntry e) => e.name)
            .take(6)
            .toList();
        if (names.isNotEmpty) {
          parts.add('[${names.join(', ')}]');
        }
      } else if (isFast) {
        parts.add('FASTED (0 cal)');
      }
      sb.writeln('- ${parts.join(' · ')}');
    }

    final String sleepLine = sleepDigest(sleep, now);
    if (sleepLine.isNotEmpty) {
      sb.writeln(sleepLine);
    }

    // Training — so the dashboard coach briefs across running too.
    if (trainerLevel > 0 || runs.isNotEmpty) {
      final int wk = runsThisWeek(runs, now);
      if (trainerLevel > 0) {
        sb.writeln('TRAINING: 5K plan level $trainerLevel of $kMaxLevel '
            '("${workoutForLevel(trainerLevel).name}"); $wk run'
            '${wk == 1 ? '' : 's'} in the last 7 days.');
      } else {
        sb.writeln('TRAINING: $wk run${wk == 1 ? '' : 's'} in the last 7 days.');
      }
      for (final RunRecord r in runs.reversed.take(4)) {
        final String dist = r.distanceKm > 0
            ? ', ${(r.distanceKm * 0.621371).toStringAsFixed(2)} mi'
            : '';
        sb.writeln('- ${r.date}: ${(r.durationSec / 60).round()} min$dist'
            '${r.avgHr != null ? ', HR ${r.avgHr!.round()}' : ''}'
            ', felt ${r.effort}${r.completed ? '' : ' (partial)'}');
      }
    }

    // Readiness — the same transparent read shown on the Sleep tab.
    final SleepEntry? lastSleep = SleepMath.latest(sleep);
    final Readiness? readiness = computeReadiness(
      lastNightHours: lastSleep?.hours,
      baselineHours: SleepMath.baselineHours(sleep, now),
      runsLast7: runsThisWeek(runs, now),
      deficit: cal.deficit,
      restingHr: lastSleep?.restingHr,
      baselineRestingHr: SleepMath.baselineRestingHr(sleep, now),
      hrv: lastSleep?.hrv,
      baselineHrv: SleepMath.baselineHrv(sleep, now),
    );
    if (readiness != null) {
      sb.writeln(
          'READINESS: ${readiness.score}/100 (${readiness.label}).');
    }

    return sb.toString();
  }
}

class AppStorage {
  static late File _file;
  static Future<void> init() async {
    // systemTemp on Android = /data/user/0/<package>/cache
    // Go up one level into /files/ for persistent storage that survives updates
    final String tempPath = Directory.systemTemp.path;
    final String appDir = Directory(tempPath).parent.path;
    final Directory filesDir = Directory('$appDir/files');
    if (!filesDir.existsSync()) {
      filesDir.createSync(recursive: true);
    }
    _file = File('${filesDir.path}/bodycomp_data.json');

    // Migrate from old temp location (earlier versions)
    final File oldFile = File('$tempPath/bodycomp_appdata.json');
    if (!_file.existsSync() && oldFile.existsSync()) {
      try {
        oldFile.copySync(_file.path);
      } catch (_) {}
    }
  }

  static Map<String, dynamic> _read() {
    try {
      if (_file.existsSync()) {
        return jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  static void _write(Map<String, dynamic> data) {
    try {
      _file.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  static UserCalibration? getCalibration() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('calibration')) {
      return UserCalibration.fromJson(d['calibration'] as Map<String, dynamic>);
    }
    return null;
  }

  static void saveCalibration(UserCalibration c) {
    final Map<String, dynamic> d = _read();
    d['calibration'] = c.toJson();
    _write(d);
  }

  static List<DailyLog> getLogs() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('logs')) {
      final List<DailyLog> logs = (d['logs'] as List<dynamic>)
          .map((dynamic e) => DailyLog.fromJson(e as Map<String, dynamic>))
          .toList();
      logs.sort((DailyLog a, DailyLog b) => a.date.compareTo(b.date));
      return logs;
    }
    return [];
  }

  static void saveLogs(List<DailyLog> logs) {
    final Map<String, dynamic> d = _read();
    d['logs'] = logs.map((DailyLog l) => l.toJson()).toList();
    _write(d);
  }

  static List<double> getDismissedMilestones() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('milestones')) {
      return (d['milestones'] as List<dynamic>)
          .map((dynamic e) => (e as num).toDouble())
          .toList();
    }
    return [];
  }

  static void saveDismissedMilestones(List<double> m) {
    final Map<String, dynamic> d = _read();
    d['milestones'] = m;
    _write(d);
  }

  static List<FoodEntry> getFoods() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('foods')) {
      return (d['foods'] as List<dynamic>)
          .map((dynamic e) => FoodEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  static void saveFoods(List<FoodEntry> foods) {
    final Map<String, dynamic> d = _read();
    d['foods'] = foods.map((FoodEntry f) => f.toJson()).toList();
    _write(d);
  }

  static List<String> getFastedDates() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('fasted')) {
      return (d['fasted'] as List<dynamic>)
          .map((dynamic e) => e as String)
          .toList();
    }
    return [];
  }

  static void saveFastedDates(List<String> dates) {
    final Map<String, dynamic> d = _read();
    d['fasted'] = dates;
    _write(d);
  }

  static List<Meal> getMeals() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('meals')) {
      return (d['meals'] as List<dynamic>)
          .map((dynamic e) => Meal.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  static void saveMeals(List<Meal> meals) {
    final Map<String, dynamic> d = _read();
    d['meals'] = meals.map((Meal m) => m.toJson()).toList();
    _write(d);
  }

  static List<CustomFood> getCustomFoods() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('customFoods')) {
      return (d['customFoods'] as List<dynamic>)
          .map((dynamic e) => CustomFood.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  static void saveCustomFoods(List<CustomFood> foods) {
    final Map<String, dynamic> d = _read();
    d['customFoods'] = foods.map((CustomFood f) => f.toJson()).toList();
    _write(d);
  }

  static String? getCustomFoodsSha() {
    final Map<String, dynamic> d = _read();
    return d['customFoodsSha'] as String?;
  }

  static void saveCustomFoodsSha(String? sha) {
    final Map<String, dynamic> d = _read();
    if (sha == null) {
      d.remove('customFoodsSha');
    } else {
      d['customFoodsSha'] = sha;
    }
    _write(d);
  }

  static List<RunRecord> getRuns() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('runs')) {
      return (d['runs'] as List<dynamic>)
          .map((dynamic e) => RunRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  static void saveRuns(List<RunRecord> runs) {
    final Map<String, dynamic> d = _read();
    d['runs'] = runs.map((RunRecord r) => r.toJson()).toList();
    _write(d);
  }

  static List<SleepEntry> getSleep() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('sleep')) {
      return (d['sleep'] as List<dynamic>)
          .map((dynamic e) => SleepEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  static void saveSleep(List<SleepEntry> entries) {
    final Map<String, dynamic> d = _read();
    d['sleep'] = entries.map((SleepEntry e) => e.toJson()).toList();
    _write(d);
  }

  static TrainerState getTrainerState() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('trainer')) {
      return TrainerState.fromJson(d['trainer'] as Map<String, dynamic>);
    }
    return const TrainerState();
  }

  static void saveTrainerState(TrainerState s) {
    final Map<String, dynamic> d = _read();
    d['trainer'] = s.toJson();
    _write(d);
  }

  static List<AdvisorInsight> getInsights() {
    final Map<String, dynamic> d = _read();
    if (d.containsKey('insights')) {
      return (d['insights'] as List<dynamic>)
          .map((dynamic e) =>
              AdvisorInsight.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  static void saveInsights(List<AdvisorInsight> insights) {
    final Map<String, dynamic> d = _read();
    d['insights'] = insights.map((AdvisorInsight i) => i.toJson()).toList();
    _write(d);
  }

  static void clearAll() {
    try {
      if (_file.existsSync()) {
        _file.deleteSync();
      }
    } catch (_) {}
  }
}

// ═══════════════════════════════════════════════════════════════════════
// DEPTH LAYERED THEME
// ═══════════════════════════════════════════════════════════════════════

class PhaseColors {
  final Color accent;
  final Color glow;
  final String label;
  const PhaseColors(this.accent, this.glow, this.label);
}

const List<PhaseColors> kPhases = [
  PhaseColors(Color(0xFF5B8FB9), Color(0x4D5B8FB9), 'Phase 0: Launch'),
  PhaseColors(Color(0xFFB44CF0), Color(0x4DB44CF0), 'Phase 1: Momentum'),
  PhaseColors(Color(0xFFF0883C), Color(0x4DF0883C), 'Phase 2: Dialed In'),
  PhaseColors(Color(0xFFF0C040), Color(0x4DF0C040), 'Phase 3: Home Stretch'),
];

// Depth layers (darkest → lightest)
const Color kBgDeep = Color(0xFF0E0E0E); // scaffold
const Color kBgNav = Color(0xFF141414); // bottom nav
const Color kSurface0 = Color(0xFF161616); // base cards (vitals)
const Color kSurface1 = Color(0xFF1A1A1A); // elevated cards (chart, goal)
const Color kSurface2 = Color(0xFF1F1F1F); // modals, sheets
const Color kSurface3 = Color(0xFF252525); // hover/active states
const Color kBorder = Color(0xFF232323);
const Color kBorderLight = Color(0xFF2C2C2C);

String formatDate(DateTime d) {
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String monthName(int m) {
  const List<String> months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return months[m - 1];
}

// ═══════════════════════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════════════════════

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppStorage.init();
  runApp(const BodyCompApp());
}

class BodyCompApp extends StatefulWidget {
  const BodyCompApp({super.key});
  @override
  State<BodyCompApp> createState() => _BodyCompAppState();
}

class _BodyCompAppState extends State<BodyCompApp> {
  UserCalibration? _cal;
  List<DailyLog> _logs = [];
  List<double> _dismissed = [];
  List<FoodEntry> _foods = [];
  List<String> _fasted = [];
  List<Meal> _meals = [];
  List<CustomFood> _customFoods = [];
  List<RunRecord> _runs = [];
  TrainerState _trainer = const TrainerState();
  List<SleepEntry> _sleep = [];
  List<AdvisorInsight> _insights = [];
  bool _syncingFoods = false;

  @override
  void initState() {
    super.initState();
    _cal = AppStorage.getCalibration();
    _logs = AppStorage.getLogs();
    _dismissed = AppStorage.getDismissedMilestones();
    _foods = AppStorage.getFoods();
    _fasted = AppStorage.getFastedDates();
    _meals = AppStorage.getMeals();
    _customFoods = AppStorage.getCustomFoods();
    _runs = AppStorage.getRuns();
    _trainer = AppStorage.getTrainerState();
    _sleep = AppStorage.getSleep();
    _insights = AppStorage.getInsights();
    // Pull the latest My Foods from the private data repo in the background.
    _syncCustomFoods();
  }

  // A cheap fingerprint of a food list for change detection.
  String _foodsFingerprint(List<CustomFood> f) {
    final List<String> ids = f
        .map((CustomFood x) => '${x.id}:${x.updatedAtMs}:${x.deleted}')
        .toList()
      ..sort();
    return ids.join('|');
  }

  /// Merge the local My Foods with the remote copy, then push if we have
  /// changes the remote doesn't. Silent + best-effort: offline or an
  /// unconfigured token just leaves the local list untouched.
  Future<void> _syncCustomFoods() async {
    if (!CustomFoodStore.isConfigured || _syncingFoods) {
      return;
    }
    _syncingFoods = true;
    try {
      final RemoteFoods? remote = await CustomFoodStore.fetchRemote();
      if (remote == null || !mounted) {
        return;
      }
      final List<CustomFood> merged =
          CustomFoodStore.mergeFoods(_customFoods, remote.foods);
      if (_foodsFingerprint(merged) != _foodsFingerprint(_customFoods)) {
        setState(() => _customFoods = merged);
        AppStorage.saveCustomFoods(merged);
      }
      if (_foodsFingerprint(merged) != _foodsFingerprint(remote.foods)) {
        final String? newSha =
            await CustomFoodStore.pushRemote(merged, remote.sha);
        if (newSha != null) {
          AppStorage.saveCustomFoodsSha(newSha);
        }
      } else if (remote.sha != null) {
        AppStorage.saveCustomFoodsSha(remote.sha);
      }
    } finally {
      _syncingFoods = false;
    }
  }

  void _setCal(UserCalibration c) {
    setState(() {
      _cal = c;
    });
    AppStorage.saveCalibration(c);
  }

  void _setLogs(List<DailyLog> l) {
    setState(() {
      _logs = l;
    });
    AppStorage.saveLogs(l);
  }

  void _dismiss(double m) {
    if (!_dismissed.contains(m)) {
      _dismissed.add(m);
      AppStorage.saveDismissedMilestones(_dismissed);
    }
  }

  void _setFoods(List<FoodEntry> f) {
    setState(() {
      _foods = f;
    });
    AppStorage.saveFoods(f);
  }

  void _setFasted(List<String> dates) {
    setState(() {
      _fasted = dates;
    });
    AppStorage.saveFastedDates(dates);
  }

  void _setMeals(List<Meal> m) {
    setState(() {
      _meals = m;
    });
    AppStorage.saveMeals(m);
  }

  void _setInsights(List<AdvisorInsight> i) {
    setState(() {
      _insights = i;
    });
    AppStorage.saveInsights(i);
  }

  void _setCustomFoods(List<CustomFood> f) {
    setState(() {
      _customFoods = f;
    });
    AppStorage.saveCustomFoods(f);
    // Push the change up to the data repo (best-effort, debounced by the flag).
    _syncCustomFoods();
  }

  void _setRuns(List<RunRecord> r) {
    setState(() {
      _runs = r;
    });
    AppStorage.saveRuns(r);
  }

  void _setTrainer(TrainerState s) {
    setState(() {
      _trainer = s;
    });
    AppStorage.saveTrainerState(s);
  }

  void _setSleep(List<SleepEntry> s) {
    setState(() {
      _sleep = s;
    });
    AppStorage.saveSleep(s);
  }

  void _resetAll() {
    AppStorage.clearAll();
    setState(() {
      _cal = null;
      _logs = [];
      _dismissed = [];
      _foods = [];
      _fasted = [];
      _meals = [];
      _customFoods = [];
      _runs = [];
      _trainer = const TrainerState();
      _sleep = [];
      _insights = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    int ph = 0;
    if (_cal != null && _logs.isNotEmpty) {
      ph = MathEngine.phase(
          MathEngine.progress(_cal!.startBf, _logs.last.bf, _cal!.targetBf));
    }
    final Color accent = kPhases[ph].accent;

    return MaterialApp(
      title: 'BodyComp',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBgDeep,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.dark(primary: accent, surface: kSurface1),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: kBgNav,
          selectedItemColor: accent,
          unselectedItemColor: const Color(0xFF555555),
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1),
          unselectedLabelStyle: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1),
        ),
      ),
      home: _cal == null
          ? SetupScreen(onDone: _setCal)
          : HomeShell(
              cal: _cal!,
              logs: _logs,
              dismissed: _dismissed,
              foods: _foods,
              fasted: _fasted,
              meals: _meals,
              customFoods: _customFoods,
              runs: _runs,
              trainer: _trainer,
              sleep: _sleep,
              insights: _insights,
              onSetCal: _setCal,
              onSetLogs: _setLogs,
              onSetFoods: _setFoods,
              onSetFasted: _setFasted,
              onSetMeals: _setMeals,
              onSetCustomFoods: _setCustomFoods,
              onSetRuns: _setRuns,
              onSetTrainer: _setTrainer,
              onSetSleep: _setSleep,
              onSetInsights: _setInsights,
              onDismiss: _dismiss,
              onReset: _resetAll),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ANIMATED NUMBER WIDGET
// ═══════════════════════════════════════════════════════════════════════

class AnimatedNum extends StatelessWidget {
  final double value;
  final int decimals;
  final TextStyle style;
  final String suffix;
  final Duration duration;

  const AnimatedNum({
    super.key,
    required this.value,
    this.decimals = 1,
    required this.style,
    this.suffix = '',
    this.duration = const Duration(milliseconds: 500),
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (BuildContext ctx, double v, Widget? child) {
        return Text('${v.toStringAsFixed(decimals)}$suffix', style: style);
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// BODY COMPOSITION RING
// ═══════════════════════════════════════════════════════════════════════

class CompositionRing extends StatelessWidget {
  final double bodyFatPct; // 0.0 - 1.0
  final double size;
  final Color accent;

  const CompositionRing(
      {super.key,
      required this.bodyFatPct,
      required this.size,
      required this.accent});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      builder: (BuildContext ctx, double anim, Widget? child) {
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(
                bodyFatPct: bodyFatPct, accent: accent, anim: anim),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedNum(
                    value: bodyFatPct * 100,
                    decimals: 1,
                    suffix: '%',
                    style: TextStyle(
                        fontSize: size * 0.18,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFFEEEEEE)),
                  ),
                  Text('BODY FAT',
                      style: TextStyle(
                          fontSize: size * 0.07,
                          color: Colors.grey[600],
                          letterSpacing: 1,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  final double bodyFatPct;
  final Color accent;
  final double anim;

  _RingPainter(
      {required this.bodyFatPct, required this.accent, required this.anim});

  @override
  void paint(Canvas canvas, Size size) {
    final double strokeW = size.width * 0.10;
    final Rect rect = Rect.fromLTWH(
        strokeW / 2, strokeW / 2, size.width - strokeW, size.height - strokeW);
    const double startAngle = -pi / 2;

    // Background track
    canvas.drawArc(
        rect,
        0,
        2 * pi,
        false,
        Paint()
          ..color = const Color(0xFF1E1E1E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round);

    // Lean mass arc (accent)
    final double leanSweep = (1 - bodyFatPct) * 2 * pi * anim;
    canvas.drawArc(
        rect,
        startAngle,
        leanSweep,
        false,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round);

    // Fat mass arc (warm color)
    final double fatSweep = bodyFatPct * 2 * pi * anim;
    canvas.drawArc(
        rect,
        startAngle + leanSweep,
        fatSweep,
        false,
        Paint()
          ..color = const Color(0xFFCC6644)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) {
    return old.bodyFatPct != bodyFatPct || old.anim != anim;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// VITAL CARD (with animated number)
// ═══════════════════════════════════════════════════════════════════════

class VitalCard extends StatelessWidget {
  final String label;
  final double? numValue;
  final String fallback;
  final int decimals;
  final String? sub;
  final Color accent;
  final Color bg;

  const VitalCard({
    super.key,
    required this.label,
    this.numValue,
    this.fallback = '—',
    this.decimals = 1,
    this.sub,
    required this.accent,
    this.bg = kSurface0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF666666),
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          numValue != null
              ? AnimatedNum(
                  value: numValue!,
                  decimals: decimals,
                  style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFEEEEEE)))
              : Text(fallback,
                  style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFEEEEEE))),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(sub!,
                style: TextStyle(
                    fontSize: 12, color: accent, fontWeight: FontWeight.w500)),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ANIMATED TREND CHART
// ═══════════════════════════════════════════════════════════════════════

class TrendChart extends StatefulWidget {
  final List<DailyLog> logs;
  final UserCalibration cal;
  final Color accent;
  const TrendChart(
      {super.key, required this.logs, required this.cal, required this.accent});

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(covariant TrendChart old) {
    super.didUpdateWidget(old);
    if (widget.logs.length != old.logs.length) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (BuildContext ctx, Widget? child) {
        return CustomPaint(
          painter: TrendPainter(
              logs: widget.logs,
              cal: widget.cal,
              accent: widget.accent,
              revealPct: _anim.value),
          size: Size.infinite,
        );
      },
    );
  }
}

class TrendPainter extends CustomPainter {
  final List<DailyLog> logs;
  final UserCalibration cal;
  final Color accent;
  final double revealPct;

  TrendPainter(
      {required this.logs,
      required this.cal,
      required this.accent,
      required this.revealPct});

  @override
  void paint(Canvas canvas, Size size) {
    if (logs.length < 2) {
      return;
    }
    final int n = logs.length;
    const double padL = 40.0, padB = 24.0, padT = 8.0, padR = 8.0;
    final double chartW = size.width - padL - padR;
    final double chartH = size.height - padT - padB;

    // Clip to reveal animation
    canvas.save();
    final double clipX = padL + chartW * revealPct;
    canvas.clipRect(Rect.fromLTRB(0, 0, clipX, size.height));

    final List<double> weights = [];
    final List<double> avgs = [];
    final List<double> uppers = [];
    final List<double> lowers = [];
    final List<double> targets = [];

    for (int i = 0; i < n; i++) {
      weights.add(logs[i].weight);
      final double avg = MathEngine.rollingAvg(logs, i);
      avgs.add(avg);
      uppers.add(avg + 1.5);
      lowers.add(avg - 1.5);
      targets.add(MathEngine.dynamicTargetWeight(logs[i].lbm, cal.targetBf));
    }

    double minY = double.infinity, maxY = double.negativeInfinity;
    for (int i = 0; i < n; i++) {
      for (final double v in [weights[i], uppers[i], lowers[i], targets[i]]) {
        if (v < minY) {
          minY = v;
        }
        if (v > maxY) {
          maxY = v;
        }
      }
    }
    final double padY = (maxY - minY) * 0.1 + 1;
    minY -= padY;
    maxY += padY;

    double toX(int i) {
      return padL + (i / (n - 1)) * chartW;
    }

    double toY(double v) {
      return padT + chartH - ((v - minY) / (maxY - minY)) * chartH;
    }

    // Grid
    final Paint gridPaint = Paint()
      ..color = const Color(0xFF1C1C1C)
      ..strokeWidth = 1;
    for (int i = 0; i <= 4; i++) {
      final double y = padT + (chartH / 4) * i;
      canvas.drawLine(Offset(padL, y), Offset(size.width - padR, y), gridPaint);
      final double val = maxY - ((maxY - minY) / 4) * i;
      final TextPainter tp = TextPainter(
          text: TextSpan(
              text: val.toStringAsFixed(0),
              style: TextStyle(fontSize: 10, color: Colors.grey[700])),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(padL - tp.width - 4, y - tp.height / 2));
    }

    final int step = max(1, n ~/ 5);
    for (int i = 0; i < n; i += step) {
      final TextPainter tp = TextPainter(
          text: TextSpan(
              text: '${i + 1}',
              style: TextStyle(fontSize: 10, color: Colors.grey[700])),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(toX(i) - tp.width / 2, size.height - padB + 6));
    }

    // Corridor
    final Path corridorPath = Path();
    corridorPath.moveTo(toX(0), toY(uppers[0]));
    for (int i = 1; i < n; i++) {
      corridorPath.lineTo(toX(i), toY(uppers[i]));
    }
    for (int i = n - 1; i >= 0; i--) {
      corridorPath.lineTo(toX(i), toY(lowers[i]));
    }
    corridorPath.close();
    canvas.drawPath(
        corridorPath,
        Paint()
          ..color =
              Color.fromRGBO(accent.red, accent.green, accent.blue, 0.07));

    // Target (dashed)
    final Paint targetP = Paint()
      ..color = Color.fromRGBO(accent.red, accent.green, accent.blue, 0.3)
      ..strokeWidth = 1;
    for (int i = 0; i < n - 1; i++) {
      if (i % 3 < 2) {
        canvas.drawLine(Offset(toX(i), toY(targets[i])),
            Offset(toX(i + 1), toY(targets[i + 1])), targetP);
      }
    }

    // Average (dashed)
    final Paint avgP = Paint()
      ..color = accent
      ..strokeWidth = 2;
    for (int i = 0; i < n - 1; i++) {
      if (i % 3 < 2) {
        canvas.drawLine(Offset(toX(i), toY(avgs[i])),
            Offset(toX(i + 1), toY(avgs[i + 1])), avgP);
      }
    }

    // Weight line
    final Path wPath = Path();
    wPath.moveTo(toX(0), toY(weights[0]));
    for (int i = 1; i < n; i++) {
      wPath.lineTo(toX(i), toY(weights[i]));
    }
    canvas.drawPath(
        wPath,
        Paint()
          ..color = const Color(0xFFEEEEEE)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke);

    // Dots
    final Paint dotP = Paint()..color = const Color(0xFFEEEEEE);
    for (int i = 0; i < n; i++) {
      canvas.drawCircle(Offset(toX(i), toY(weights[i])), 2.5, dotP);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TrendPainter old) {
    return true;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SETUP SCREEN
// ═══════════════════════════════════════════════════════════════════════

class SetupScreen extends StatefulWidget {
  final void Function(UserCalibration) onDone;
  const SetupScreen({super.key, required this.onDone});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final TextEditingController _wC = TextEditingController();
  final TextEditingController _bfC = TextEditingController();
  final TextEditingController _tbfC = TextEditingController();
  final TextEditingController _defC = TextEditingController(text: '500');
  double _am = 1.4;

  bool get _ok {
    final double? w = double.tryParse(_wC.text);
    final double? bf = double.tryParse(_bfC.text);
    final double? tbf = double.tryParse(_tbfC.text);
    final int? def = int.tryParse(_defC.text);
    return w != null &&
        w > 0 &&
        bf != null &&
        bf > 0 &&
        bf < 100 &&
        tbf != null &&
        tbf > 0 &&
        tbf < bf &&
        def != null &&
        def > 0;
  }

  @override
  void dispose() {
    _wC.dispose();
    _bfC.dispose();
    _tbfC.dispose();
    _defC.dispose();
    super.dispose();
  }

  InputDecoration _dec(String hint) {
    return InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFF111111),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF333333))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF333333))));
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = kPhases[0].accent;
    return Scaffold(
        body: SafeArea(
            child: Center(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('BODYCOMP',
                              style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                  color: Colors.white)),
                          const SizedBox(height: 4),
                          Text(
                              'Set your baseline. Everything else is calculated dynamically.',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey[600],
                                  height: 1.5)),
                          const SizedBox(height: 32),
                          _f('STARTING WEIGHT (LBS)', _wC, 'e.g. 210'),
                          const SizedBox(height: 16),
                          _f('CURRENT BODY FAT %', _bfC, 'e.g. 25'),
                          const SizedBox(height: 16),
                          _f('TARGET BODY FAT %', _tbfC, 'e.g. 15'),
                          const SizedBox(height: 16),
                          _f('DAILY CALORIC DEFICIT', _defC, 'e.g. 500'),
                          const SizedBox(height: 16),
                          _lbl('ACTIVITY LEVEL'),
                          const SizedBox(height: 6),
                          Container(
                            decoration: BoxDecoration(
                                color: const Color(0xFF111111),
                                borderRadius: BorderRadius.circular(10),
                                border:
                                    Border.all(color: const Color(0xFF333333))),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: DropdownButtonHideUnderline(
                                child: DropdownButton<double>(
                                    value: _am,
                                    isExpanded: true,
                                    dropdownColor: kSurface2,
                                    style: const TextStyle(
                                        color: Color(0xFFEEEEEE), fontSize: 16),
                                    items: const [
                                      DropdownMenuItem(
                                          value: 1.2,
                                          child: Text('Sedentary (1.2)')),
                                      DropdownMenuItem(
                                          value: 1.375,
                                          child: Text('Light (1.375)')),
                                      DropdownMenuItem(
                                          value: 1.4,
                                          child: Text('Moderate (1.4)')),
                                      DropdownMenuItem(
                                          value: 1.55,
                                          child: Text('Active (1.55)')),
                                      DropdownMenuItem(
                                          value: 1.725,
                                          child: Text('Very Active (1.725)')),
                                    ],
                                    onChanged: (double? v) {
                                      if (v != null) {
                                        setState(() {
                                          _am = v;
                                        });
                                      }
                                    })),
                          ),
                          const SizedBox(height: 28),
                          SizedBox(
                              width: double.infinity,
                              height: 54,
                              child: ElevatedButton(
                                onPressed: _ok
                                    ? () {
                                        widget.onDone(UserCalibration(
                                            startWeight: double.parse(_wC.text),
                                            startBf:
                                                double.parse(_bfC.text) / 100,
                                            targetBf:
                                                double.parse(_tbfC.text) / 100,
                                            activityMult: _am,
                                            deficit: int.parse(_defC.text)));
                                      }
                                    : null,
                                style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        _ok ? accent : const Color(0xFF333333),
                                    foregroundColor: _ok
                                        ? Colors.black
                                        : const Color(0xFF666666),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    textStyle: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800)),
                                child: const Text('CALIBRATE'),
                              )),
                        ])))));
  }

  Widget _lbl(String t) {
    return Text(t,
        style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF777777),
            letterSpacing: 1,
            fontWeight: FontWeight.w600));
  }

  Widget _f(String label, TextEditingController c, String hint) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _lbl(label),
      const SizedBox(height: 6),
      TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 17, color: Color(0xFFEEEEEE)),
          decoration: _dec(hint),
          onChanged: (_) {
            setState(() {});
          }),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// HOME SHELL
// ═══════════════════════════════════════════════════════════════════════

class HomeShell extends StatefulWidget {
  final UserCalibration cal;
  final List<DailyLog> logs;
  final List<double> dismissed;
  final List<FoodEntry> foods;
  final List<String> fasted;
  final List<Meal> meals;
  final List<CustomFood> customFoods;
  final List<RunRecord> runs;
  final TrainerState trainer;
  final List<SleepEntry> sleep;
  final List<AdvisorInsight> insights;
  final void Function(UserCalibration) onSetCal;
  final void Function(List<DailyLog>) onSetLogs;
  final void Function(List<FoodEntry>) onSetFoods;
  final void Function(List<String>) onSetFasted;
  final void Function(List<Meal>) onSetMeals;
  final void Function(List<CustomFood>) onSetCustomFoods;
  final void Function(List<RunRecord>) onSetRuns;
  final void Function(TrainerState) onSetTrainer;
  final void Function(List<SleepEntry>) onSetSleep;
  final void Function(List<AdvisorInsight>) onSetInsights;
  final void Function(double) onDismiss;
  final VoidCallback onReset;
  const HomeShell(
      {super.key,
      required this.cal,
      required this.logs,
      required this.dismissed,
      required this.foods,
      required this.fasted,
      required this.meals,
      required this.customFoods,
      required this.runs,
      required this.trainer,
      required this.sleep,
      required this.insights,
      required this.onSetCal,
      required this.onSetLogs,
      required this.onSetFoods,
      required this.onSetFasted,
      required this.onSetMeals,
      required this.onSetCustomFoods,
      required this.onSetRuns,
      required this.onSetTrainer,
      required this.onSetSleep,
      required this.onSetInsights,
      required this.onDismiss,
      required this.onReset});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    int ph = 0;
    if (widget.logs.isNotEmpty) {
      ph = MathEngine.phase(MathEngine.progress(
          widget.cal.startBf, widget.logs.last.bf, widget.cal.targetBf));
    }
    final Color accent = kPhases[ph].accent;
    return Scaffold(
      body: SafeArea(
          child: IndexedStack(index: _tab, children: [
        DashboardScreen(
            cal: widget.cal,
            logs: widget.logs,
            dismissed: widget.dismissed,
            foods: widget.foods,
            fasted: widget.fasted,
            sleep: widget.sleep,
            runs: widget.runs,
            trainer: widget.trainer,
            insights: widget.insights,
            onSetLogs: widget.onSetLogs,
            onSetInsights: widget.onSetInsights,
            onDismiss: widget.onDismiss),
        FoodScreen(
            cal: widget.cal,
            logs: widget.logs,
            foods: widget.foods,
            fasted: widget.fasted,
            meals: widget.meals,
            customFoods: widget.customFoods,
            onSetFoods: widget.onSetFoods,
            onSetFasted: widget.onSetFasted,
            onSetMeals: widget.onSetMeals,
            onSetCustomFoods: widget.onSetCustomFoods),
        _CookScreen(
            accent: accent,
            meals: widget.meals,
            onSetMeals: widget.onSetMeals,
            logDate: formatDate(DateTime.now()),
            embedded: true,
            onLogFood: (FoodEntry e) =>
                widget.onSetFoods(<FoodEntry>[...widget.foods, e])),
        TrainScreen(
            accent: accent,
            cal: widget.cal,
            logs: widget.logs,
            runs: widget.runs,
            trainer: widget.trainer,
            sleep: widget.sleep,
            onSetRuns: widget.onSetRuns,
            onSetTrainer: widget.onSetTrainer),
        SleepScreen(
            accent: accent,
            cal: widget.cal,
            logs: widget.logs,
            runs: widget.runs,
            sleep: widget.sleep,
            onSetSleep: widget.onSetSleep),
        SettingsScreen(
            cal: widget.cal,
            logs: widget.logs,
            onSetCal: widget.onSetCal,
            onSetLogs: widget.onSetLogs,
            onReset: widget.onReset),
      ])),
      bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tab,
          onTap: (int i) {
            setState(() {
              _tab = i;
            });
          },
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.dashboard_rounded), label: 'DASHBOARD'),
            BottomNavigationBarItem(
                icon: Icon(Icons.restaurant_rounded), label: 'FOOD'),
            BottomNavigationBarItem(
                icon: Icon(Icons.outdoor_grill_rounded), label: 'COOK'),
            BottomNavigationBarItem(
                icon: Icon(Icons.directions_run_rounded), label: 'TRAIN'),
            BottomNavigationBarItem(
                icon: Icon(Icons.bedtime_rounded), label: 'SLEEP'),
            BottomNavigationBarItem(
                icon: Icon(Icons.settings_rounded), label: 'SETTINGS'),
          ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// DASHBOARD
// ═══════════════════════════════════════════════════════════════════════

class DashboardScreen extends StatefulWidget {
  final UserCalibration cal;
  final List<DailyLog> logs;
  final List<double> dismissed;
  final List<FoodEntry> foods;
  final List<String> fasted;
  final List<SleepEntry> sleep;
  final List<RunRecord> runs;
  final TrainerState trainer;
  final List<AdvisorInsight> insights;
  final void Function(List<DailyLog>) onSetLogs;
  final void Function(List<AdvisorInsight>) onSetInsights;
  final void Function(double) onDismiss;
  const DashboardScreen(
      {super.key,
      required this.cal,
      required this.logs,
      required this.dismissed,
      required this.foods,
      required this.fasted,
      required this.sleep,
      required this.runs,
      required this.trainer,
      required this.insights,
      required this.onSetLogs,
      required this.onSetInsights,
      required this.onDismiss});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _plateauDismissed = false;
  int _chartRange = 0;

  // Sleep-aware context for a weight jump (null unless it's worth saying).
  String? get _scaleNoise {
    if (widget.logs.length < 2) {
      return null;
    }
    final double delta =
        widget.logs.last.weight - widget.logs[widget.logs.length - 2].weight;
    return scaleNoiseNote(delta, SleepMath.latest(widget.sleep)?.hours);
  }

  double get _progress {
    return widget.logs.isEmpty
        ? 0
        : MathEngine.progress(
            widget.cal.startBf, widget.logs.last.bf, widget.cal.targetBf);
  }

  int get _phase => MathEngine.phase(_progress);
  PhaseColors get _pc => kPhases[_phase];

  bool get _loggedToday {
    if (widget.logs.isEmpty) {
      return false;
    }
    return widget.logs.last.date == formatDate(DateTime.now());
  }

  @override
  void didUpdateWidget(covariant DashboardScreen old) {
    super.didUpdateWidget(old);
    if (widget.logs.length != old.logs.length) {
      _checkMilestones();
    }
  }

  void _checkMilestones() {
    final double p = _progress;
    for (final double t in [0.25, 0.50, 0.75]) {
      if (p >= t && !widget.dismissed.contains(t)) {
        widget.onDismiss(t);
        final (double fl, double mp, int d) = _mStats();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) {
                return MilestoneDialog(
                    milestone: t,
                    fatLost: fl,
                    musclePct: mp,
                    days: d,
                    accent: _pc.accent);
              });
        });
        break;
      }
    }
  }

  (double, double, int) _mStats() {
    if (widget.logs.isEmpty) {
      return (0.0, 100.0, 0);
    }
    final DailyLog l = widget.logs.last;
    double mp = 100.0;
    if (widget.cal.startLbm > 0) {
      mp = (l.lbm / widget.cal.startLbm) * 100;
    }
    return (widget.cal.startFatMass - l.fatMass, mp, widget.logs.length);
  }

  void _showLogModal({String? editDate}) {
    DailyLog? existing;
    if (editDate != null) {
      final int idx =
          widget.logs.indexWhere((DailyLog l) => l.date == editDate);
      if (idx >= 0) {
        existing = widget.logs[idx];
      }
    } else if (_loggedToday) {
      existing = widget.logs.last;
    }

    // For a brand-new weigh-in, pre-fill calories with yesterday's count
    // (food-log total if food was logged, else the number entered that day),
    // still fully editable.
    int? prefillCal;
    if (existing == null) {
      final String yDate =
          formatDate(DateTime.now().subtract(const Duration(days: 1)));
      final double foodCal = FoodMath.caloriesByDate(widget.foods)[yDate] ?? 0;
      if (foodCal > 0) {
        prefillCal = foodCal.round();
      } else {
        final int yi = widget.logs.indexWhere((DailyLog l) => l.date == yDate);
        if (yi >= 0 && widget.logs[yi].calories > 0) {
          prefillCal = widget.logs[yi].calories;
        }
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) {
        return LogModal(
          accent: _pc.accent,
          existingDates: widget.logs.map((DailyLog l) => l.date).toSet(),
          initDate: existing?.date,
          initW: existing?.weight,
          initBf: existing != null ? existing.bf * 100 : null,
          initCal: existing?.calories ?? prefillCal,
          onSave: (String date, double w, double bf, int cal) {
            final DailyLog newLog =
                DailyLog(date: date, weight: w, bf: bf, calories: cal);
            final List<DailyLog> logs = List<DailyLog>.from(widget.logs);
            final int idx = logs.indexWhere((DailyLog l) => l.date == date);
            if (idx >= 0) {
              logs[idx] = newLog;
            } else {
              logs.add(newLog);
            }
            logs.sort((DailyLog a, DailyLog b) => a.date.compareTo(b.date));
            widget.onSetLogs(logs);
            Navigator.pop(context);
          },
        );
      },
    );
  }

  List<DailyLog> get _chartLogs {
    if (_chartRange <= 0 || widget.logs.length <= _chartRange) {
      return widget.logs;
    }
    return widget.logs.sublist(widget.logs.length - _chartRange);
  }

  Future<void> _onRefresh() async {
    HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final DailyLog? latest = widget.logs.isNotEmpty ? widget.logs.last : null;
    final double? lbm = latest?.lbm;
    double? targetWt;
    if (lbm != null) {
      targetWt = MathEngine.dynamicTargetWeight(lbm, widget.cal.targetBf);
    }
    double? tdee;
    if (widget.logs.isNotEmpty) {
      tdee = MathEngine.activeTdee(widget.logs, widget.cal.activityMult,
          caloriesByDate: FoodMath.caloriesByDate(widget.foods),
          fastedDates: widget.fasted.toSet());
    }
    double? delta;
    if (widget.logs.length >= 2) {
      delta =
          widget.logs.last.weight - widget.logs[widget.logs.length - 2].weight;
    }
    final bool plateau = MathEngine.isPlateau(widget.logs);
    final Color accent = _pc.accent;
    final int? daysToGoal =
        MathEngine.daysToGoal(widget.logs, widget.cal.targetBf);
    final DateTime? goalDate =
        MathEngine.goalDate(widget.logs, widget.cal.targetBf);

    return Stack(children: [
      RefreshIndicator(
        onRefresh: _onRefresh,
        color: accent,
        backgroundColor: kSurface1,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              if (_scaleNoise != null) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: const Color(0xFF14181F),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF243246))),
                  child: Row(children: [
                    const Icon(Icons.bedtime_rounded,
                        color: Color(0xFF7FA8E8), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(_scaleNoise!,
                            style: const TextStyle(
                                color: Color(0xFFB8CBEA),
                                fontSize: 12,
                                height: 1.4))),
                  ]),
                ),
              ],
              // Header
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_pc.label.toUpperCase(),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          letterSpacing: 2)),
                  const SizedBox(height: 2),
                  Text('${(_progress * 100).toStringAsFixed(0)}% to goal',
                      style: TextStyle(fontSize: 11, color: Colors.grey[700])),
                ]),
                Text('BODYCOMP',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                        color: Colors.grey[700])),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF1A1A1A),
                      valueColor: AlwaysStoppedAnimation<Color>(accent))),
              const SizedBox(height: 16),

              // AI coach card
              _AdvisorCard(
                  cal: widget.cal,
                  logs: widget.logs,
                  foods: widget.foods,
                  fasted: widget.fasted,
                  sleep: widget.sleep,
                  runs: widget.runs,
                  trainerLevel: widget.trainer.level,
                  insights: widget.insights,
                  onSetInsights: widget.onSetInsights,
                  accent: accent),
              const SizedBox(height: 14),

              // Chart card (elevated surface)
              Container(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
                decoration: BoxDecoration(
                    color: kSurface1,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('TREND CORRIDOR',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                    letterSpacing: 1,
                                    fontWeight: FontWeight.w600)),
                            Row(children: [
                              _rBtn('30d', 30, accent),
                              const SizedBox(width: 4),
                              _rBtn('60d', 60, accent),
                              const SizedBox(width: 4),
                              _rBtn('All', 0, accent)
                            ]),
                          ]),
                      const SizedBox(height: 8),
                      SizedBox(
                          height: 200,
                          child: _chartLogs.length < 2
                              ? Center(
                                  child: Text(
                                      'Log at least 2 days to see your chart',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.grey[700])))
                              : TrendChart(
                                  key: ValueKey<int>(_chartRange),
                                  logs: _chartLogs,
                                  cal: widget.cal,
                                  accent: accent)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 16, runSpacing: 4, children: [
                        _leg(const Color(0xFFEEEEEE), 'Daily Weight'),
                        _leg(accent, '7d Average'),
                        _leg(
                            Color.fromRGBO(
                                accent.red, accent.green, accent.blue, 0.35),
                            'Target'),
                      ]),
                    ]),
              ),
              const SizedBox(height: 14),

              // Composition ring + Weight card row
              if (latest != null) ...[
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CompositionRing(
                      bodyFatPct: latest.bf, size: 130, accent: accent),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(children: [
                    VitalCard(
                        label: 'Weight',
                        numValue: latest.weight,
                        sub: delta != null
                            ? '${delta > 0 ? '+' : ''}${delta.toStringAsFixed(1)} lbs'
                            : null,
                        accent: accent),
                    const SizedBox(height: 10),
                    VitalCard(
                        label: 'Lean Mass',
                        numValue: lbm,
                        sub: 'lbs',
                        accent: accent),
                  ])),
                ]),
                const SizedBox(height: 10),
              ],

              // TDEE + Target row
              Row(children: [
                Expanded(
                    child: VitalCard(
                        label: 'TDEE Target',
                        numValue:
                            tdee != null ? tdee - widget.cal.deficit : null,
                        decimals: 0,
                        sub: tdee != null
                            ? 'cal (−${widget.cal.deficit})'
                            : null,
                        accent: accent,
                        bg: kSurface0)),
                const SizedBox(width: 10),
                Expanded(
                    child: VitalCard(
                        label: 'Dynamic Target',
                        numValue: targetWt,
                        sub: targetWt != null ? 'lbs' : null,
                        accent: accent,
                        bg: kSurface0)),
              ]),
              const SizedBox(height: 14),

              // Goal projection
              if (goalDate != null && daysToGoal != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: kSurface1,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: kBorder)),
                  child: Row(children: [
                    const Text('🎯', style: TextStyle(fontSize: 24)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('PROJECTED GOAL',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey[600],
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(
                              '${monthName(goalDate.month)} ${goalDate.day}, ${goalDate.year}',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: accent)),
                          Text('$daysToGoal days at current pace',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[600])),
                        ])),
                  ]),
                ),
                const SizedBox(height: 10),
              ],

              // Plateau
              if (plateau && !_plateauDismissed) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: kSurface1,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: Color.fromRGBO(
                              accent.red, accent.green, accent.blue, 0.2))),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('📊 10-Day Plateau Detected',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFCCCCCC))),
                        const SizedBox(height: 6),
                        Text(
                            'Your rolling average has moved less than 0.5 lbs in 10 days.',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                                height: 1.5)),
                        const SizedBox(height: 10),
                        Row(children: [
                          ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _plateauDismissed = true;
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: accent,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8))),
                              child: const Text('Recalculate TDEE',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700))),
                          const SizedBox(width: 8),
                          TextButton(
                              onPressed: () {
                                setState(() {
                                  _plateauDismissed = true;
                                });
                              },
                              child: Text('Dismiss',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey[600]))),
                        ]),
                      ]),
                ),
              ],

              if (widget.logs.isEmpty)
                Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('Tap LOG TODAY to record your first entry.',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 14, color: Colors.grey[600]))),
            ]),
      ),

      // LOG / LOGGED button
      Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: () {
                  _showLogModal();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _loggedToday ? kSurface3 : accent,
                  foregroundColor: _loggedToday ? accent : Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: _loggedToday
                          ? BorderSide(
                              color: Color.fromRGBO(
                                  accent.red, accent.green, accent.blue, 0.3))
                          : BorderSide.none),
                  elevation: _loggedToday ? 0 : 8,
                  shadowColor: _loggedToday ? Colors.transparent : _pc.glow,
                  textStyle: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5),
                ),
                child: Text(_loggedToday ? 'LOGGED ✓' : 'LOG TODAY'),
              ))),
    ]);
  }

  Widget _rBtn(String label, int range, Color accent) {
    final bool active = _chartRange == range;
    return GestureDetector(
      onTap: () {
        setState(() {
          _chartRange = range;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: active ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border:
                Border.all(color: active ? accent : const Color(0xFF333333))),
        child: Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: active ? Colors.black : Colors.grey[600])),
      ),
    );
  }

  Widget _leg(Color c, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 16,
          height: 2,
          decoration:
              BoxDecoration(color: c, borderRadius: BorderRadius.circular(1))),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// LOG MODAL
// ═══════════════════════════════════════════════════════════════════════

class LogModal extends StatefulWidget {
  final Color accent;
  final void Function(String date, double weight, double bf, int calories)
      onSave;
  final Set<String>? existingDates;
  final String? initDate;
  final double? initW;
  final double? initBf;
  final int? initCal;
  final VoidCallback? onDelete;
  const LogModal(
      {super.key,
      required this.accent,
      required this.onSave,
      this.existingDates,
      this.initDate,
      this.initW,
      this.initBf,
      this.initCal,
      this.onDelete});
  @override
  State<LogModal> createState() => _LogModalState();
}

class _LogModalState extends State<LogModal> {
  late DateTime _date;
  late final TextEditingController _wC, _bfC, _calC;

  @override
  void initState() {
    super.initState();
    _date = widget.initDate != null
        ? DateTime.parse(widget.initDate!)
        : DateTime.now();
    _wC = TextEditingController(text: widget.initW?.toString() ?? '');
    _bfC = TextEditingController(text: widget.initBf?.toStringAsFixed(1) ?? '');
    String ct = '';
    if (widget.initCal != null && widget.initCal! > 0) {
      ct = widget.initCal.toString();
    }
    _calC = TextEditingController(text: ct);
  }

  @override
  void dispose() {
    _wC.dispose();
    _bfC.dispose();
    _calC.dispose();
    super.dispose();
  }

  bool get _ok {
    final double? w = double.tryParse(_wC.text);
    final double? bf = double.tryParse(_bfC.text);
    return w != null && w > 0 && bf != null && bf > 0 && bf < 100;
  }

  InputDecoration _dec(String hint) {
    return InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFF111111),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF333333))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF333333))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: widget.accent)));
  }

  Future<void> _pick() async {
    final DateTime? p = await showDatePicker(
        context: context,
        initialDate: _date,
        firstDate: DateTime(2020),
        lastDate: DateTime.now(),
        builder: (BuildContext ctx, Widget? child) {
          return Theme(
              data: ThemeData.dark().copyWith(
                  colorScheme: ColorScheme.dark(
                      primary: widget.accent, surface: kSurface2)),
              child: child!);
        });
    if (p != null) {
      setState(() {
        _date = p;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final String ds = formatDate(_date);
    final bool isToday = ds == formatDate(DateTime.now());
    final bool has =
        widget.existingDates != null && widget.existingDates!.contains(ds);

    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.initW != null ? 'Edit Entry' : 'Log Entry',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: widget.accent)),
            const SizedBox(height: 16),
            GestureDetector(
                onTap: _pick,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF333333))),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('DATE',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey[600],
                                      letterSpacing: 1,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(isToday ? '$ds (Today)' : ds,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFEEEEEE))),
                            ]),
                        Icon(Icons.calendar_today_rounded,
                            color: Colors.grey[600], size: 20),
                      ]),
                )),
            if (has && widget.initW == null) ...[
              const SizedBox(height: 4),
              Text('  ⚠ Will overwrite existing entry.',
                  style: TextStyle(fontSize: 11, color: Colors.orange[400]))
            ],
            const SizedBox(height: 14),
            _lbl('WEIGHT (LBS)'),
            const SizedBox(height: 4),
            TextField(
                controller: _wC,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(fontSize: 17, color: Color(0xFFEEEEEE)),
                decoration: _dec('e.g. 195'),
                onChanged: (_) {
                  setState(() {});
                }),
            const SizedBox(height: 14),
            _lbl('BODY FAT %'),
            const SizedBox(height: 4),
            TextField(
                controller: _bfC,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(fontSize: 17, color: Color(0xFFEEEEEE)),
                decoration: _dec('e.g. 22'),
                onChanged: (_) {
                  setState(() {});
                }),
            const SizedBox(height: 14),
            _lbl("YESTERDAY'S CALORIES"),
            const SizedBox(height: 4),
            TextField(
                controller: _calC,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 17, color: Color(0xFFEEEEEE)),
                decoration: _dec('optional')),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                  child: SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _ok
                            ? () {
                                widget.onSave(
                                    ds,
                                    double.parse(_wC.text),
                                    double.parse(_bfC.text) / 100,
                                    int.tryParse(_calC.text) ?? 0);
                              }
                            : null,
                        style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _ok ? widget.accent : const Color(0xFF333333),
                            foregroundColor:
                                _ok ? Colors.black : const Color(0xFF666666),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            textStyle: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        child: const Text('Save'),
                      ))),
              const SizedBox(width: 10),
              TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: Text('Cancel',
                      style: TextStyle(color: Colors.grey[500], fontSize: 15))),
            ]),
            if (widget.onDelete != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: widget.onDelete,
                    style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFCC5555),
                        side: const BorderSide(color: Color(0xFF442222)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 10)),
                    child: const Text('Delete This Entry',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ))
            ],
          ]),
    );
  }

  Widget _lbl(String t) {
    return Text(t,
        style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF777777),
            letterSpacing: 1,
            fontWeight: FontWeight.w600));
  }
}

// ═══════════════════════════════════════════════════════════════════════
// MILESTONE DIALOG
// ═══════════════════════════════════════════════════════════════════════

class MilestoneDialog extends StatelessWidget {
  final double milestone;
  final double fatLost;
  final double musclePct;
  final int days;
  final Color accent;
  const MilestoneDialog(
      {super.key,
      required this.milestone,
      required this.fatLost,
      required this.musclePct,
      required this.days,
      required this.accent});

  @override
  Widget build(BuildContext context) {
    final int pct = (milestone * 100).toInt();
    String h = '$pct% MOMENTUM!';
    if (pct == 50) {
      h = '$pct% HALFWAY THERE!';
    } else if (pct == 75) {
      h = '$pct% HOME STRETCH!';
    }
    return Dialog(
      backgroundColor: kSurface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🔥', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(h,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w800, color: accent)),
            const SizedBox(height: 20),
            RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFFAAAAAA), height: 1.7),
                    children: [
                      const TextSpan(text: "You've logged "),
                      TextSpan(
                          text: '$days',
                          style: const TextStyle(
                              color: Color(0xFFEEEEEE),
                              fontWeight: FontWeight.w700)),
                      const TextSpan(text: ' days.\nLost '),
                      TextSpan(
                          text: '${fatLost.toStringAsFixed(1)} lbs',
                          style: const TextStyle(
                              color: Color(0xFFEEEEEE),
                              fontWeight: FontWeight.w700)),
                      const TextSpan(text: ' of fat.\nMaintained '),
                      TextSpan(
                          text: '${musclePct.toStringAsFixed(0)}%',
                          style: TextStyle(
                              color: accent, fontWeight: FontWeight.w700)),
                      const TextSpan(text: ' of your muscle mass.'),
                    ])),
            const SizedBox(height: 28),
            SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    child: const Text("LET'S GO"))),
          ])),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// LEDGER
// ═══════════════════════════════════════════════════════════════════════

class LedgerScreen extends StatelessWidget {
  final List<DailyLog> logs;
  final UserCalibration cal;
  final void Function(List<DailyLog>) onSetLogs;
  const LedgerScreen(
      {super.key,
      required this.logs,
      required this.cal,
      required this.onSetLogs});

  @override
  Widget build(BuildContext context) {
    int ph = 0;
    if (logs.isNotEmpty) {
      ph = MathEngine.phase(
          MathEngine.progress(cal.startBf, logs.last.bf, cal.targetBf));
    }
    final Color accent = kPhases[ph].accent;
    if (logs.isEmpty) {
      return Center(
          child: Text('No entries yet.',
              style: TextStyle(fontSize: 13, color: Colors.grey[700])));
    }

    final List<DailyLog> rev = logs.reversed.toList();
    return ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: rev.length + 1,
        itemBuilder: (BuildContext ctx, int idx) {
          if (idx == 0) {
            return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('HISTORY (${logs.length} entries)',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        letterSpacing: 1,
                        fontWeight: FontWeight.w600)));
          }
          final DailyLog log = rev[idx - 1];
          final int oi = logs.length - idx;
          return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: kSurface0,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    _edit(ctx, log, oi, accent);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: kBorder)),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(log.date,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFDDDDDD))),
                                const SizedBox(height: 2),
                                Text(
                                    'LBM: ${log.lbm.toStringAsFixed(1)} lbs${log.calories > 0 ? ' · ${log.calories} cal' : ''}',
                                    style: TextStyle(
                                        fontSize: 11, color: Colors.grey[600])),
                              ]),
                          Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(log.weight.toStringAsFixed(1),
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFFEEEEEE))),
                                Text('${(log.bf * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: accent,
                                        fontWeight: FontWeight.w600)),
                              ]),
                        ]),
                  ),
                ),
              ));
        });
  }

  void _edit(BuildContext context, DailyLog log, int idx, Color accent) {
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: kSurface2,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) {
          return LogModal(
              accent: accent,
              initDate: log.date,
              initW: log.weight,
              initBf: log.bf * 100,
              initCal: log.calories,
              onSave: (String date, double w, double bf, int cal) {
                final List<DailyLog> u = List<DailyLog>.from(logs);
                u[idx] = DailyLog(date: date, weight: w, bf: bf, calories: cal);
                onSetLogs(u);
                Navigator.pop(context);
              },
              onDelete: () {
                final List<DailyLog> u = List<DailyLog>.from(logs);
                u.removeAt(idx);
                onSetLogs(u);
                Navigator.pop(context);
              });
        });
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SETTINGS
// ═══════════════════════════════════════════════════════════════════════

class SettingsScreen extends StatefulWidget {
  final UserCalibration cal;
  final List<DailyLog> logs;
  final void Function(UserCalibration) onSetCal;
  final void Function(List<DailyLog>) onSetLogs;
  final VoidCallback onReset;
  const SettingsScreen(
      {super.key,
      required this.cal,
      required this.logs,
      required this.onSetCal,
      required this.onSetLogs,
      required this.onReset});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _editing = false;
  bool _confirmReset = false;
  late TextEditingController _tbfC, _defC, _proteinC, _fatC, _carbC, _fiberC;
  late double _am;

  @override
  void initState() {
    super.initState();
    _tbfC = TextEditingController(
        text: (widget.cal.targetBf * 100).toStringAsFixed(1));
    _defC = TextEditingController(text: widget.cal.deficit.toString());
    _proteinC = TextEditingController(
        text: widget.cal.proteinTarget != null
            ? _trim(widget.cal.proteinTarget!)
            : '');
    _fatC = TextEditingController(
        text:
            widget.cal.fatTarget != null ? _trim(widget.cal.fatTarget!) : '');
    _carbC = TextEditingController(
        text: widget.cal.carbTarget != null
            ? _trim(widget.cal.carbTarget!)
            : '');
    _fiberC = TextEditingController(
        text: widget.cal.fiberTarget != null
            ? _trim(widget.cal.fiberTarget!)
            : '');
    _am = widget.cal.activityMult;
  }

  @override
  void dispose() {
    _tbfC.dispose();
    _defC.dispose();
    _proteinC.dispose();
    _fatC.dispose();
    _carbC.dispose();
    _fiberC.dispose();
    super.dispose();
  }

  Color get _accent {
    int ph = 0;
    if (widget.logs.isNotEmpty) {
      ph = MathEngine.phase(MathEngine.progress(
          widget.cal.startBf, widget.logs.last.bf, widget.cal.targetBf));
    }
    return kPhases[ph].accent;
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = _accent;
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('CONFIGURATION',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600))),
          if (!_editing) ...[
            Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: kSurface1,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kBorder)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('CURRENT CALIBRATION',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                              letterSpacing: 1,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      _row('Start Weight', '${widget.cal.startWeight}'),
                      _row('Start BF',
                          '${(widget.cal.startBf * 100).toStringAsFixed(1)}%'),
                      _row('Target BF',
                          '${(widget.cal.targetBf * 100).toStringAsFixed(1)}%',
                          vc: accent),
                      _row('Activity', '${widget.cal.activityMult}x'),
                      _row('Deficit', '${widget.cal.deficit} cal'),
                    ])),
            const SizedBox(height: 12),
            _btn('✏️  Edit Settings', () {
              setState(() {
                _editing = true;
              });
            }),
          ] else ...[
            Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: kSurface1,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: Color.fromRGBO(
                            accent.red, accent.green, accent.blue, 0.2))),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _fl('TARGET BODY FAT %'),
                      const SizedBox(height: 6),
                      TextField(
                          controller: _tbfC,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          style: const TextStyle(
                              fontSize: 16, color: Color(0xFFEEEEEE)),
                          decoration: _fDec()),
                      const SizedBox(height: 14),
                      _fl('DAILY CALORIC DEFICIT'),
                      const SizedBox(height: 6),
                      TextField(
                          controller: _defC,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(
                              fontSize: 16, color: Color(0xFFEEEEEE)),
                          decoration: _fDec()),
                      const SizedBox(height: 14),
                      _fl('ACTIVITY MULTIPLIER'),
                      const SizedBox(height: 6),
                      Container(
                          decoration: BoxDecoration(
                              color: const Color(0xFF111111),
                              borderRadius: BorderRadius.circular(10),
                              border:
                                  Border.all(color: const Color(0xFF333333))),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: DropdownButtonHideUnderline(
                              child: DropdownButton<double>(
                                  value: _am,
                                  isExpanded: true,
                                  dropdownColor: kSurface2,
                                  style: const TextStyle(
                                      color: Color(0xFFEEEEEE), fontSize: 16),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 1.2,
                                        child: Text('Sedentary (1.2)')),
                                    DropdownMenuItem(
                                        value: 1.375,
                                        child: Text('Light (1.375)')),
                                    DropdownMenuItem(
                                        value: 1.4,
                                        child: Text('Moderate (1.4)')),
                                    DropdownMenuItem(
                                        value: 1.55,
                                        child: Text('Active (1.55)')),
                                    DropdownMenuItem(
                                        value: 1.725,
                                        child: Text('Very Active (1.725)')),
                                  ],
                                  onChanged: (double? v) {
                                    if (v != null) {
                                      setState(() {
                                        _am = v;
                                      });
                                    }
                                  }))),
                      const SizedBox(height: 16),
                      _fl('MACRO TARGETS (g/day — blank = auto)'),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(child: _macroField('Protein', _proteinC)),
                        const SizedBox(width: 10),
                        Expanded(child: _macroField('Fat', _fatC)),
                      ]),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(child: _macroField('Carbs', _carbC)),
                        const SizedBox(width: 10),
                        Expanded(child: _macroField('Fiber', _fiberC)),
                      ]),
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                            child: ElevatedButton(
                                onPressed: () {
                                  final double? tbf =
                                      double.tryParse(_tbfC.text);
                                  final int? def = int.tryParse(_defC.text);
                                  if (tbf == null ||
                                      tbf <= 0 ||
                                      tbf >= 100 ||
                                      def == null ||
                                      def <= 0) {
                                    return;
                                  }
                                  double? ovr(TextEditingController c) {
                                    final double? v = double.tryParse(c.text);
                                    return (v != null && v > 0) ? v : null;
                                  }

                                  widget.onSetCal(UserCalibration(
                                      startWeight: widget.cal.startWeight,
                                      startBf: widget.cal.startBf,
                                      targetBf: tbf / 100,
                                      activityMult: _am,
                                      deficit: def,
                                      proteinTarget: ovr(_proteinC),
                                      fatTarget: ovr(_fatC),
                                      carbTarget: ovr(_carbC),
                                      fiberTarget: ovr(_fiberC)));
                                  setState(() {
                                    _editing = false;
                                  });
                                },
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: accent,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10))),
                                child: const Text('Save',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700)))),
                        const SizedBox(width: 10),
                        TextButton(
                            onPressed: () {
                              setState(() {
                                _editing = false;
                              });
                            },
                            child: Text('Cancel',
                                style: TextStyle(color: Colors.grey[500]))),
                      ]),
                    ])),
          ],
          const SizedBox(height: 12),
          _advisorCard(accent),
          const SizedBox(height: 12),
          UpdateCard(accent: accent),
          const SizedBox(height: 12),
          _btn('📒  Weight Ledger', () {
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                backgroundColor: kBgDeep,
                appBar: AppBar(
                    backgroundColor: kBgDeep,
                    foregroundColor: const Color(0xFFEEEEEE),
                    title: const Text('Weight Ledger')),
                body: SafeArea(
                    child: LedgerScreen(
                        logs: widget.logs,
                        cal: widget.cal,
                        onSetLogs: widget.onSetLogs)),
              ),
            ));
          }),
          const SizedBox(height: 12),
          _btn('📁  Export CSV to Clipboard', _csv),
          const SizedBox(height: 12),
          if (!_confirmReset)
            _btn('🗑  Reset All Data', () {
              setState(() {
                _confirmReset = true;
              });
            }, color: const Color(0xFF884444), border: const Color(0xFF331A1A))
          else
            Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: kSurface1,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF442222))),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('This will delete everything. Are you sure?',
                          style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFFCC5555),
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                            child: ElevatedButton(
                                onPressed: () {
                                  widget.onReset();
                                  setState(() {
                                    _confirmReset = false;
                                  });
                                },
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFCC4444),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10))),
                                child: const Text('Yes, Reset',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700)))),
                        const SizedBox(width: 10),
                        TextButton(
                            onPressed: () {
                              setState(() {
                                _confirmReset = false;
                              });
                            },
                            child: Text('Cancel',
                                style: TextStyle(color: Colors.grey[500]))),
                      ]),
                    ])),
        ]);
  }

  Widget _row(String l, String v, {Color? vc}) {
    return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(l, style: TextStyle(fontSize: 13, color: Colors.grey[500])),
          Text(v,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: vc ?? const Color(0xFFEEEEEE)))
        ]));
  }

  Widget _advisorCard(Color accent) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('AI COACH',
            style: TextStyle(
                fontSize: 11,
                color: Colors.grey[600],
                letterSpacing: 1,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Model used for daily/weekly coaching. Pricier = sharper.',
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF333333))),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: widget.cal.advisorModel,
              isExpanded: true,
              dropdownColor: kSurface2,
              style: const TextStyle(color: Color(0xFFEEEEEE), fontSize: 15),
              items: kAdvisorModels
                  .map((AdvisorModel m) => DropdownMenuItem<String>(
                      value: m.id,
                      child: Text('${m.label}  (${m.cost})')))
                  .toList(),
              onChanged: (String? v) {
                if (v != null) {
                  widget.onSetCal(widget.cal.copyWith(advisorModel: v));
                }
              },
            ),
          ),
        ),
        if (!Advisor.configured) ...<Widget>[
          const SizedBox(height: 8),
          Text('No API key in this build — coaching is disabled until one is added.',
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ],
      ]),
    );
  }

  Widget _btn(String t, VoidCallback onTap, {Color? color, Color? border}) {
    return Material(
        color: kSurface0,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: border ?? kBorder)),
                child: Text(t,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: color ?? const Color(0xFFCCCCCC))))));
  }

  Widget _fl(String t) {
    return Text(t,
        style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF777777),
            letterSpacing: 1,
            fontWeight: FontWeight.w600));
  }

  InputDecoration _fDec() {
    return InputDecoration(
        filled: true,
        fillColor: const Color(0xFF111111),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF333333))));
  }

  Widget _macroField(String label, TextEditingController c) {
    return TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 15, color: Color(0xFFEEEEEE)),
        decoration: _fDec().copyWith(
            labelText: label,
            labelStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
            hintText: 'auto',
            hintStyle: const TextStyle(color: Color(0xFF555555)),
            isDense: true));
  }

  void _csv() {
    final StringBuffer buf =
        StringBuffer('Date,Weight,BodyFat%,Calories,LBM,TargetWeight\n');
    for (final DailyLog l in widget.logs) {
      final double tw =
          MathEngine.dynamicTargetWeight(l.lbm, widget.cal.targetBf);
      buf.writeln(
          '${l.date},${l.weight},${(l.bf * 100).toStringAsFixed(1)},${l.calories},${l.lbm.toStringAsFixed(1)},${tw.toStringAsFixed(1)}');
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('CSV copied to clipboard.'),
        backgroundColor: Color(0xFF2A2A2A)));
  }
}

// ═══════════════════════════════════════════════════════════════════════
// FOOD JOURNAL UI
// ═══════════════════════════════════════════════════════════════════════

String _trim(double v, {int dp = 0}) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(dp);

class FoodScreen extends StatefulWidget {
  final UserCalibration cal;
  final List<DailyLog> logs;
  final List<FoodEntry> foods;
  final List<String> fasted;
  final List<Meal> meals;
  final List<CustomFood> customFoods;
  final void Function(List<FoodEntry>) onSetFoods;
  final void Function(List<String>) onSetFasted;
  final void Function(List<Meal>) onSetMeals;
  final void Function(List<CustomFood>) onSetCustomFoods;
  const FoodScreen(
      {super.key,
      required this.cal,
      required this.logs,
      required this.foods,
      required this.fasted,
      required this.meals,
      required this.customFoods,
      required this.onSetFoods,
      required this.onSetFasted,
      required this.onSetMeals,
      required this.onSetCustomFoods});
  @override
  State<FoodScreen> createState() => _FoodScreenState();
}

class _FoodScreenState extends State<FoodScreen> {
  late String _date;
  String? _pendingTime; // set when adding via a specific hour slot

  @override
  void initState() {
    super.initState();
    _date = formatDate(DateTime.now());
  }

  Color get _accent {
    int ph = 0;
    if (widget.logs.isNotEmpty) {
      ph = MathEngine.phase(MathEngine.progress(
          widget.cal.startBf, widget.logs.last.bf, widget.cal.targetBf));
    }
    return kPhases[ph].accent;
  }

  MacroTargets get _targets => MacroTargets.compute(
      widget.cal, widget.logs, widget.foods, widget.fasted.toSet());

  void _shiftDay(int delta) {
    // Future dates allowed — useful for planning meals ahead.
    final DateTime d = DateTime.parse(_date).add(Duration(days: delta));
    setState(() => _date = formatDate(d));
  }

  bool get _isFasted => widget.fasted.contains(_date);

  void _toggleFasted() {
    final List<String> f = List<String>.from(widget.fasted);
    if (!f.remove(_date)) {
      f.add(_date);
    }
    widget.onSetFasted(f);
  }

  String _nowTime() {
    final DateTime n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  // Time stamped onto a newly-added entry: the tapped hour slot, else now.
  String _timeForNew() => _pendingTime ?? _nowTime();

  void _addAtHour(int hour) {
    _pendingTime = '${hour.toString().padLeft(2, '0')}:00';
    _showAddMenu();
  }

  /// Picks a date, then a time. Returns (date 'YYYY-MM-DD', time 'HH:mm').
  // Pick a day (calendar), then a time (scroll wheels). Returns (date, time).
  Future<(String, String)?> _pickDateTime(
      String initialDate, String initialTime) async {
    final DateTime? d = await showDatePicker(
        context: context,
        initialDate: DateTime.parse(initialDate),
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        builder: (BuildContext ctx, Widget? child) => Theme(
            data: ThemeData.dark().copyWith(
                colorScheme:
                    ColorScheme.dark(primary: _accent, surface: kSurface2)),
            child: child!));
    if (d == null || !mounted) {
      return null;
    }
    final String? time = await showScrollTime(
        context, _accent, initialTime.isEmpty ? _nowTime() : initialTime);
    if (time == null) {
      return null;
    }
    return (formatDate(d), time);
  }

  // ── Multi-select ──
  final Set<String> _selected = <String>{};
  bool get _selecting => _selected.isNotEmpty;

  void _toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) {
        _selected.add(id);
      }
    });
  }

  void _clearSelection() => setState(_selected.clear);

  List<FoodEntry> _selectedEntries() =>
      widget.foods.where((FoodEntry e) => _selected.contains(e.id)).toList();

  void _editSelected() {
    final List<FoodEntry> list = _selectedEntries();
    if (list.length != 1) {
      return;
    }
    final FoodEntry e = list.first;
    _clearSelection();
    _openEntryEditor(e);
  }

  // Move and Modify Timestamp both set the date+time of the whole selection.
  Future<void> _stampSelected() async {
    final List<FoodEntry> list = _selectedEntries();
    if (list.isEmpty) {
      return;
    }
    final (String, String)? dt =
        await _pickDateTime(list.first.date, list.first.time);
    if (dt == null) {
      return;
    }
    final Set<String> ids = Set<String>.from(_selected);
    widget.onSetFoods(widget.foods
        .map((FoodEntry e) =>
            ids.contains(e.id) ? e.copyWith(date: dt.$1, time: dt.$2) : e)
        .toList());
    _clearSelection();
  }

  Future<void> _copySelected() async {
    final List<FoodEntry> list = _selectedEntries();
    if (list.isEmpty) {
      return;
    }
    final (String, String)? dt =
        await _pickDateTime(list.first.date, list.first.time);
    if (dt == null) {
      return;
    }
    final int base = DateTime.now().microsecondsSinceEpoch;
    final List<FoodEntry> copies = <FoodEntry>[];
    for (int i = 0; i < list.length; i++) {
      copies.add(list[i].copyWith(id: '${base}_$i', date: dt.$1, time: dt.$2));
    }
    widget.onSetFoods(<FoodEntry>[...widget.foods, ...copies]);
    _clearSelection();
  }

  void _viewSelected() {
    final List<FoodEntry> list = _selectedEntries();
    if (list.isEmpty) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _SelectionBreakdown(entries: list, accent: _accent),
    );
  }

  String _dateLabel() {
    final DateTime d = DateTime.parse(_date);
    final DateTime today = DateTime.parse(formatDate(DateTime.now()));
    final int diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff == 0) {
      return 'Today';
    }
    if (diff == 1) {
      return 'Yesterday';
    }
    const List<String> wd = [
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun'
    ];
    return '${wd[d.weekday - 1]}, ${monthName(d.month)} ${d.day}';
  }

  void _addEntry(FoodEntry e) {
    widget.onSetFoods(List<FoodEntry>.from(widget.foods)..add(e));
    _pendingTime = null; // consumed
  }

  void _updateEntry(FoodEntry e) {
    widget.onSetFoods(
        widget.foods.map((FoodEntry x) => x.id == e.id ? e : x).toList());
  }

  void _deleteEntry(String id) {
    widget.onSetFoods(
        widget.foods.where((FoodEntry x) => x.id != id).toList());
  }

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  void _showAddMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          _menuTile(Icons.bookmark_rounded, 'My Foods',
              '$_myFoodsCount saved — log one in a tap', () {
            Navigator.pop(context);
            _openMyFoods();
          }),
          const Divider(height: 1, color: Color(0xFF222222)),
          _menuTile(Icons.qr_code_scanner_rounded, 'Scan barcode',
              'Look up nutrition automatically', () {
            Navigator.pop(context);
            _scanBarcode();
          }),
          _menuTile(Icons.document_scanner_rounded, 'Scan label',
              'Read a Nutrition Facts panel with the camera', () {
            Navigator.pop(context);
            _scanLabel();
          }),
          _menuTile(Icons.search_rounded, 'Search by name',
              'For foods without a barcode (e.g. onion)', () {
            Navigator.pop(context);
            _searchFood();
          }),
          _menuTile(Icons.restaurant_menu_rounded, 'Cook a meal',
              'Combine ingredients, portion by calories', () {
            Navigator.pop(context);
            _openMeals();
          }),
          _menuTile(Icons.edit_rounded, 'Enter manually',
              'Type in the food and its nutrition', () {
            Navigator.pop(context);
            _openEditor();
          }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _menuTile(
      IconData icon, String title, String sub, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: _accent),
      title: Text(title,
          style: const TextStyle(
              color: Color(0xFFEEEEEE), fontWeight: FontWeight.w600)),
      subtitle: Text(sub, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      onTap: onTap,
    );
  }

  Future<void> _scanBarcode() async {
    final String? code = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(builder: (_) => _ScannerPage(accent: _accent)));
    if (code == null || !mounted) {
      return;
    }
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Center(
            child: CircularProgressIndicator(color: _accent)));
    FoodTemplate? t;
    try {
      t = await FoodLookup.barcode(code);
    } catch (_) {}
    if (!mounted) {
      return;
    }
    Navigator.pop(context); // dismiss the loader
    if (t == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFF2A2A2A),
          content: Text('Barcode $code not found — enter it manually.')));
      _openEditor(barcode: code);
      return;
    }
    _openConfirm(t);
  }

  Future<void> _searchFood() async {
    final FoodTemplate? t = await Navigator.of(context).push<FoodTemplate>(
        MaterialPageRoute<FoodTemplate>(
            builder: (_) => _FoodSearchPage(accent: _accent)));
    if (t == null || !mounted) {
      return;
    }
    _openConfirm(t);
  }

  void _openMeals() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _CookScreen(
        accent: _accent,
        meals: widget.meals,
        onSetMeals: widget.onSetMeals,
        logDate: _date,
        onLogFood: _addEntry,
      ),
    ));
  }

  void _openConfirm(FoodTemplate t, {String source = 'barcode'}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ConfirmFoodSheet(
        template: t,
        accent: _accent,
        onSave: (double grams, String label) {
          _addEntry(t.toEntry(
              id: _newId(),
              date: _date,
              grams: grams,
              servingLabel: label,
              time: _timeForNew(),
              source: source));
          Navigator.pop(context);
        },
      ),
    );
  }

  void _openEditor(
      {FoodEntry? existing,
      String? barcode,
      LabelParse? prefill,
      String source = 'manual'}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ManualFoodSheet(
        accent: _accent,
        existing: existing,
        prefill: prefill,
        onSave: (FoodEntry e, double? servingGrams) {
          if (existing != null) {
            // Editing a log entry edits that entry in place — no rescale flow.
            _updateEntry(e);
            Navigator.pop(context);
            return;
          }
          // A new food: save it to My Foods (per serving), then open the
          // grams/servings scaling sheet so the amount eaten needs no math.
          final CustomFood food =
              _saveTemplateFromEntry(e, source, servingGrams);
          Navigator.pop(context); // close the editor
          _logCustomFood(food);
        },
        onDelete: existing == null
            ? null
            : () {
                _deleteEntry(existing.id);
                Navigator.pop(context);
              },
        onMove: null, // move/copy now handled via long-press selection banner
        onCopy: null,
        buildEntry: (String name, String serving, double cal, double p,
            double f, double c, Map<String, double> micros) {
          return FoodEntry(
            id: existing?.id ?? _newId(),
            date: existing?.date ?? _date,
            time: existing?.time ?? _timeForNew(),
            name: name,
            serving: serving,
            calories: cal,
            protein: p,
            fat: f,
            carbs: c,
            nutrients: micros,
            source: existing?.source ?? source,
            barcode: existing?.barcode ?? barcode,
          );
        },
      ),
    );
  }

  // Edit an already-logged food: change grams/servings and every macro
  // re-scales automatically (no manual math), with fine-tune still possible.
  void _openEntryEditor(FoodEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _EditEntrySheet(
        accent: _accent,
        entry: entry,
        onSave: (FoodEntry e) {
          _updateEntry(e);
          Navigator.pop(context);
        },
        onDelete: () {
          _deleteEntry(entry.id);
          Navigator.pop(context);
        },
      ),
    );
  }

  // ── My Foods (reusable saved foods) ──────────────────────────────────
  int get _myFoodsCount =>
      widget.customFoods.where((CustomFood f) => !f.deleted).length;

  /// Save (or update) a food as a reusable My Food and return it. The stored
  /// macros are PER SERVING. De-dupes on name+serving+source so re-scanning
  /// the same product updates in place.
  CustomFood _saveTemplateFromEntry(FoodEntry e, String source, double? grams) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String key = '${e.name.toLowerCase().trim()}|'
        '${e.serving.toLowerCase().trim()}|$source';
    CustomFood? existing;
    for (final CustomFood f in widget.customFoods) {
      if (!f.deleted &&
          '${f.name.toLowerCase().trim()}|'
                  '${f.serving.toLowerCase().trim()}|${f.source}' ==
              key) {
        existing = f;
        break;
      }
    }
    final CustomFood food = CustomFood(
      id: existing?.id ?? 'cf_${DateTime.now().microsecondsSinceEpoch}',
      name: e.name,
      serving: e.serving,
      servingGrams: grams ?? existing?.servingGrams,
      calories: e.calories,
      protein: e.protein,
      fat: e.fat,
      carbs: e.carbs,
      nutrients: Map<String, double>.from(e.nutrients),
      source: source,
      barcode: e.barcode,
      updatedAtMs: now,
    );
    widget.onSetCustomFoods(
        CustomFoodStore.mergeFoods(widget.customFoods, <CustomFood>[food]));
    return food;
  }

  /// Log a saved food, scaling live: by grams↔servings if its weight is
  /// known (same sheet as barcode), otherwise by servings.
  void _logCustomFood(CustomFood food) {
    if (food.hasGrams) {
      _openConfirm(food.toTemplate(), source: food.source);
    } else {
      _openServings(food);
    }
  }

  void _openServings(CustomFood food) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _QuantitySheet(accent: _accent, food: food),
    ).then((dynamic qty) {
      if (qty is double && mounted) {
        _addEntry(food.toEntry(
          id: _newId(),
          date: _date,
          quantity: qty,
          time: _timeForNew(),
        ));
      }
    });
  }

  void _openMyFoods() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _MyFoodsPage(
        accent: _accent,
        foods: widget.customFoods,
        onSetFoods: widget.onSetCustomFoods,
        onPick: (CustomFood food) {
          Navigator.pop(context); // close the My Foods page
          _logCustomFood(food);
        },
      ),
    ));
  }

  // ── Nutrition-label OCR ──────────────────────────────────────────────
  Future<void> _scanLabel() async {
    XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
          source: ImageSource.camera, maxWidth: 2200, imageQuality: 92);
    } catch (_) {}
    if (shot == null || !mounted) {
      return;
    }
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            Center(child: CircularProgressIndicator(color: _accent)));
    String text = '';
    final TextRecognizer recognizer =
        TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final RecognizedText r =
          await recognizer.processImage(InputImage.fromFilePath(shot.path));
      text = r.text;
    } catch (_) {
    } finally {
      await recognizer.close();
    }
    if (!mounted) {
      return;
    }
    Navigator.pop(context); // dismiss the loader
    final LabelParse parse = parseNutritionLabel(text);
    if (!parse.hasAnything) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: Color(0xFF2A2A2A),
          content: Text(
              "Couldn't read the label — fill it in (or retake the photo).")));
    }
    // Pre-fill the editor with whatever we read; the user confirms/corrects.
    _openEditor(prefill: parse, source: 'label');
  }

  int _hourOf(FoodEntry e) =>
      e.time.length >= 2 ? (int.tryParse(e.time.split(':').first) ?? 12) : 12;

  List<Widget> _hourGrid(List<FoodEntry> dayFoods, Color accent) {
    final Map<int, List<FoodEntry>> byHour = <int, List<FoodEntry>>{};
    for (final FoodEntry e in dayFoods) {
      (byHour[_hourOf(e)] ??= <FoodEntry>[]).add(e);
    }
    int start = 6, end = 21; // default visible window, expands to fit entries
    if (byHour.isNotEmpty) {
      start = min(start, byHour.keys.reduce(min));
      end = max(end, byHour.keys.reduce(max));
    }
    final List<Widget> out = <Widget>[];
    for (int h = start; h <= end; h++) {
      final List<FoodEntry> list = byHour[h] ?? <FoodEntry>[];
      out.add(InkWell(
        onTap: () => _addAtHour(h),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
          child: Row(children: <Widget>[
            SizedBox(
                width: 52,
                child: Text('${h.toString().padLeft(2, '0')}:00',
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[list.isEmpty ? 700 : 500],
                        fontWeight: FontWeight.w600))),
            Expanded(
                child: Container(height: 1, color: const Color(0xFF1C1C1C))),
            const SizedBox(width: 8),
            Icon(Icons.add_circle_outline_rounded,
                size: 16, color: Colors.grey[700]),
          ]),
        ),
      ));
      for (final FoodEntry e in list) {
        out.add(Padding(
          padding: const EdgeInsets.only(left: 52),
          child: _FoodCard(
              entry: e,
              accent: accent,
              selected: _selected.contains(e.id),
              onLongPress: () => _toggleSelect(e.id),
              onTap: () => _selecting
                  ? _toggleSelect(e.id)
                  : _openEntryEditor(e)),
        ));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = _accent;
    final List<FoodEntry> dayFoods = FoodMath.forDate(widget.foods, _date);
    final DayTotals totals = FoodMath.totals(widget.foods, _date);
    final MacroTargets targets = _targets;

    return Stack(children: [
      ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        // Date navigator
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          IconButton(
              onPressed: () => _shiftDay(-1),
              icon: const Icon(Icons.chevron_left_rounded,
                  color: Color(0xFF888888))),
          Text(_dateLabel(),
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFEEEEEE))),
          IconButton(
              onPressed: () => _shiftDay(1),
              icon: const Icon(Icons.chevron_right_rounded,
                  color: Color(0xFF888888))),
        ]),
        const SizedBox(height: 4),
        _BudgetHeader(totals: totals, targets: targets, accent: accent),
        const SizedBox(height: 8),
        if (dayFoods.isEmpty) _fastedCard(accent),
        ..._hourGrid(dayFoods, accent),
        if (totals.nutrients.isNotEmpty) ...[
          const SizedBox(height: 10),
          _MicroPanel(nutrients: totals.nutrients),
        ],
      ]),
      Positioned(
        bottom: 16,
        left: 16,
        right: 16,
        child: _selecting
            ? _selectionBanner(accent)
            : SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: () {
                    _pendingTime = null;
                    _showAddMenu();
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('ADD FOOD',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5)),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                ),
              ),
      ),
    ]);
  }

  Widget _selectionBanner(Color accent) {
    final int n = _selected.length;
    final bool multi = n > 1;
    Widget action(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                Icon(icon, color: Colors.black, size: 20),
                const SizedBox(height: 2),
                Text(label,
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.black)),
              ]),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
          color: accent, borderRadius: BorderRadius.circular(14)),
      child: Row(children: <Widget>[
        InkWell(
          onTap: _clearSelection,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              const Icon(Icons.close_rounded, color: Colors.black, size: 20),
              const SizedBox(width: 4),
              Text('$n',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Colors.black)),
            ]),
          ),
        ),
        Container(width: 1, height: 30, color: Colors.black26),
        action(multi ? Icons.visibility_rounded : Icons.edit_rounded,
            multi ? 'View' : 'Edit', multi ? _viewSelected : _editSelected),
        action(Icons.copy_rounded, 'Copy', _copySelected),
        action(Icons.drive_file_move_rounded, 'Move', _stampSelected),
        action(Icons.schedule_rounded, 'Timestamp', _stampSelected),
      ]),
    );
  }

  Widget _fastedCard(Color accent) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(children: [
        Text(
            _isFasted
                ? 'Marked as a fasted day.\nCounts as 0 calories in your TDEE.'
                : 'No food logged for this day.\nTap + to scan or add.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey[600], height: 1.5)),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: _toggleFasted,
          icon: Icon(
              _isFasted
                  ? Icons.check_circle_rounded
                  : Icons.no_meals_rounded,
              size: 18),
          label: Text(_isFasted ? 'Fasted day ✓ (tap to undo)' : 'Mark as fasted day'),
          style: OutlinedButton.styleFrom(
              foregroundColor: _isFasted ? accent : Colors.grey[400],
              side: BorderSide(
                  color: _isFasted
                      ? accent
                      : const Color(0xFF333333)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
        ),
      ]),
    );
  }
}

// ─── Budget header: calorie + macro progress vs targets ───
class _BudgetHeader extends StatelessWidget {
  final DayTotals totals;
  final MacroTargets targets;
  final Color accent;
  const _BudgetHeader(
      {required this.totals, required this.targets, required this.accent});

  @override
  Widget build(BuildContext context) {
    final double cal = totals.calories;
    final double calTarget = targets.calories;
    final double? remaining = calTarget > 0 ? calTarget - cal : null;
    final double frac =
        calTarget > 0 ? (cal / calTarget).clamp(0.0, 1.0) : 0.0;
    final bool over = remaining != null && remaining < 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${cal.round()}',
              style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFEEEEEE))),
          const SizedBox(width: 4),
          Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(calTarget > 0 ? '/ ${calTarget.round()} cal' : 'cal',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]))),
          const Spacer(),
          if (remaining != null)
            Text(over ? '${(-remaining).round()} over' : '${remaining.round()} left',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: over ? const Color(0xFFCC6644) : accent)),
        ]),
        if (calTarget > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: frac,
                  minHeight: 6,
                  backgroundColor: const Color(0xFF111111),
                  valueColor: AlwaysStoppedAnimation<Color>(
                      over ? const Color(0xFFCC6644) : accent))),
        ],
        const SizedBox(height: 16),
        Row(children: [
          _macroBar('Protein', totals.protein, targets.protein, accent),
          const SizedBox(width: 10),
          _macroBar('Fat', totals.fat, targets.fat, accent),
          const SizedBox(width: 10),
          _macroBar('Carbs', totals.carbs, targets.carbs, accent),
          const SizedBox(width: 10),
          _macroBar(
              'Fiber', totals.nutrients['fiber'] ?? 0, targets.fiber, accent),
        ]),
      ]),
    );
  }

  Widget _macroBar(String label, double v, double target, Color accent) {
    final double frac = target > 0 ? (v / target).clamp(0.0, 1.0) : 0.0;
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 9,
                color: Colors.grey[600],
                letterSpacing: 0.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 3),
        Text('${_trim(v)}/${_trim(target)}g',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFFEEEEEE))),
        const SizedBox(height: 4),
        ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
                value: frac,
                minHeight: 4,
                backgroundColor: const Color(0xFF111111),
                valueColor: AlwaysStoppedAnimation<Color>(accent))),
      ]),
    );
  }
}

// ─── A single logged food row ───
class _FoodCard extends StatelessWidget {
  final FoodEntry entry;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  const _FoodCard(
      {required this.entry,
      required this.accent,
      required this.onTap,
      this.onLongPress,
      this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? kSurface3 : kSurface0,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: selected ? accent : kBorder,
                    width: selected ? 1.5 : 1)),
            child: Row(children: [
              if (selected) ...[
                Icon(Icons.check_circle_rounded, size: 18, color: accent),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFDDDDDD))),
                      const SizedBox(height: 3),
                      Text(
                          '${entry.serving}  ·  P ${_trim(entry.protein)}  F ${_trim(entry.fat)}  C ${_trim(entry.carbs)}',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[600])),
                    ]),
              ),
              const SizedBox(width: 10),
              Text('${entry.calories.round()}',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: accent)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─── Breakdown of a multi-selection ───
class _SelectionBreakdown extends StatelessWidget {
  final List<FoodEntry> entries;
  final Color accent;
  const _SelectionBreakdown({required this.entries, required this.accent});

  @override
  Widget build(BuildContext context) {
    double cal = 0, p = 0, f = 0, c = 0;
    for (final FoodEntry e in entries) {
      cal += e.calories;
      p += e.protein;
      f += e.fat;
      c += e.carbs;
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewPadding.bottom + 20),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('${entries.length} items selected',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: accent)),
            const SizedBox(height: 4),
            Text(
                'Combined: ${cal.round()} cal · P ${_trim(p)} · F ${_trim(f)} · C ${_trim(c)}',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            const SizedBox(height: 14),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (BuildContext ctx, int i) {
                  final FoodEntry e = entries[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(children: <Widget>[
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(e.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      color: Color(0xFFDDDDDD))),
                              const SizedBox(height: 2),
                              Text(
                                  '${e.serving}${e.time.isNotEmpty ? ' · ${e.time}' : ''} · ${e.date}',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey[600])),
                            ]),
                      ),
                      Text('${e.calories.round()}',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: accent)),
                    ]),
                  );
                },
              ),
            ),
          ]),
    );
  }
}

// ─── Collapsible day micronutrient totals ───
class _MicroPanel extends StatelessWidget {
  final Map<String, double> nutrients;
  const _MicroPanel({required this.nutrients});

  @override
  Widget build(BuildContext context) {
    final List<Nutrient> present = kNutrients
        .where((Nutrient n) => (nutrients[n.key] ?? 0) > 0)
        .toList();
    if (present.isEmpty) {
      return const SizedBox.shrink();
    }
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        decoration: BoxDecoration(
            color: kSurface0,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kBorder)),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          iconColor: const Color(0xFF888888),
          collapsedIconColor: const Color(0xFF888888),
          title: Text('NUTRIENTS (${present.length})',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
          children: present
              .map((Nutrient n) => Padding(
                    padding:
                        const EdgeInsets.fromLTRB(14, 0, 14, 10),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(n.label,
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey[400])),
                          Text(
                              '${_trim(nutrients[n.key]!, dp: 1)} ${n.unit}',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFDDDDDD))),
                        ]),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

// ─── Full-screen barcode scanner ───
class _ScannerPage extends StatefulWidget {
  final Color accent;
  const _ScannerPage({required this.accent});
  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  // v7 requires you to own the controller's lifecycle (create → start →
  // dispose). Relying on the widget's auto-created controller was what
  // crashed with the ML Kit null-reference error.
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: kBgDeep,
          foregroundColor: const Color(0xFFEEEEEE),
          title: const Text('Scan barcode')),
      body: Stack(children: [
        MobileScanner(
          controller: _controller,
          onDetect: (BarcodeCapture capture) {
            if (_handled) {
              return;
            }
            for (final Barcode b in capture.barcodes) {
              final String? code = b.rawValue;
              if (code != null && code.isNotEmpty) {
                _handled = true;
                Navigator.of(context).pop(code);
                return;
              }
            }
          },
        ),
        Center(
          child: Container(
            width: 240,
            height: 140,
            decoration: BoxDecoration(
                border: Border.all(color: widget.accent, width: 3),
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
        Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Text('Point at a barcode',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85), fontSize: 14)),
        ),
      ]),
    );
  }
}

// ─── Search foods by name (Open Food Facts) ───
class _FoodSearchPage extends StatefulWidget {
  final Color accent;
  const _FoodSearchPage({required this.accent});
  @override
  State<_FoodSearchPage> createState() => _FoodSearchPageState();
}

class _FoodSearchPageState extends State<_FoodSearchPage> {
  final TextEditingController _q = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  bool _searched = false;
  List<FoodTemplate> _results = <FoodTemplate>[];
  int _reqId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _run(v));
  }

  Future<void> _run(String v) async {
    if (v.trim().isEmpty) {
      setState(() {
        _results = <FoodTemplate>[];
        _searched = false;
      });
      return;
    }
    final int id = ++_reqId;
    setState(() => _loading = true);
    List<FoodTemplate> r = <FoodTemplate>[];
    try {
      r = await FoodLookup.search(v);
    } catch (_) {}
    if (!mounted || id != _reqId) {
      return; // a newer search superseded this one
    }
    setState(() {
      _results = r;
      _loading = false;
      _searched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgDeep,
      appBar: AppBar(
          backgroundColor: kBgDeep,
          foregroundColor: const Color(0xFFEEEEEE),
          title: const Text('Search food')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _q,
            autofocus: true,
            style: const TextStyle(fontSize: 16, color: Color(0xFFEEEEEE)),
            decoration: _foodDec(widget.accent).copyWith(
                hintText: 'e.g. onion, chicken breast, oats',
                prefixIcon:
                    const Icon(Icons.search_rounded, color: Color(0xFF888888))),
            onChanged: _onChanged,
            onSubmitted: _run,
          ),
        ),
        if (_loading) LinearProgressIndicator(color: widget.accent, minHeight: 2),
        Expanded(
          child: _searched && _results.isEmpty && !_loading
              ? Center(
                  child: Text('No matches. Try a simpler term or enter it manually.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600], fontSize: 13)))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: _results.length,
                  itemBuilder: (BuildContext ctx, int i) {
                    final FoodTemplate t = _results[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: kSurface0,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.of(context).pop(t),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: kBorder)),
                            child: Row(children: [
                              Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(t.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFFDDDDDD))),
                                      const SizedBox(height: 3),
                                      Text(
                                          '${t.kcal100.round()} cal · P ${_trim(t.protein100)} F ${_trim(t.fat100)} C ${_trim(t.carbs100)}  (per 100 g)',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey[600])),
                                    ]),
                              ),
                              Icon(Icons.add_circle_outline_rounded,
                                  color: widget.accent, size: 20),
                            ]),
                          ),
                        ),
                      ),
                    );
                  }),
        ),
      ]),
    );
  }
}

// ─── Confirm a scanned food + pick serving size ───
class _ConfirmFoodSheet extends StatefulWidget {
  final FoodTemplate template;
  final Color accent;
  final void Function(double grams, String label) onSave;
  const _ConfirmFoodSheet(
      {required this.template, required this.accent, required this.onSave});
  @override
  State<_ConfirmFoodSheet> createState() => _ConfirmFoodSheetState();
}

class _ConfirmFoodSheetState extends State<_ConfirmFoodSheet> {
  late final TextEditingController _gramsC;
  late final TextEditingController _servingsC;
  bool _syncing = false;

  bool get _hasServing =>
      widget.template.servingGrams != null && widget.template.servingGrams! > 0;
  double get _servingG => widget.template.servingGrams ?? 0;

  @override
  void initState() {
    super.initState();
    final double initGrams = _hasServing ? _servingG : 100;
    _gramsC = TextEditingController(text: _trim(initGrams, dp: 1));
    _servingsC = TextEditingController(text: _hasServing ? '1' : '');
  }

  @override
  void dispose() {
    _gramsC.dispose();
    _servingsC.dispose();
    super.dispose();
  }

  double get _grams => double.tryParse(_gramsC.text) ?? 0;

  // The two fields stay in sync; _syncing guards against feedback loops.
  void _onGrams(String v) {
    if (_syncing) {
      return;
    }
    _syncing = true;
    if (_hasServing) {
      final double? g = double.tryParse(v);
      _servingsC.text = g != null ? _trim(g / _servingG, dp: 2) : '';
    }
    _syncing = false;
    setState(() {});
  }

  void _onServings(String v) {
    if (_syncing) {
      return;
    }
    _syncing = true;
    final double? s = double.tryParse(v);
    _gramsC.text = s != null ? _trim(s * _servingG, dp: 1) : '';
    _syncing = false;
    setState(() {});
  }

  String get _label {
    if (_hasServing) {
      final double? s = double.tryParse(_servingsC.text);
      if (s != null) {
        final String unit = s == 1 ? 'serving' : 'servings';
        return '${_trim(s, dp: 2)} $unit (${_trim(_grams)} g)';
      }
    }
    return '${_trim(_grams)} g';
  }

  @override
  Widget build(BuildContext context) {
    final FoodTemplate t = widget.template;
    final double s = _grams / 100.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.name,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: widget.accent)),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Expanded(child: _amountField('GRAMS', _gramsC, _onGrams)),
              if (_hasServing) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(
                    child: _amountField(
                        'SERVINGS (${_trim(_servingG)} g)',
                        _servingsC,
                        _onServings)),
              ],
            ]),
            const SizedBox(height: 16),
            Row(children: [
              _stat('Calories', '${(t.kcal100 * s).round()}', widget.accent),
              _stat('Protein', '${_trim(t.protein100 * s)} g', widget.accent),
              _stat('Fat', '${_trim(t.fat100 * s)} g', widget.accent),
              _stat('Carbs', '${_trim(t.carbs100 * s)} g', widget.accent),
            ]),
            const SizedBox(height: 20),
            SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed:
                      _grams > 0 ? () => widget.onSave(_grams, _label) : null,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: widget.accent,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: const Color(0xFF333333),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  child: const Text('Log it'),
                )),
          ]),
    );
  }

  Widget _amountField(
      String label, TextEditingController c, void Function(String) onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(label,
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              letterSpacing: 1,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 17, color: Color(0xFFEEEEEE)),
          decoration: _foodDec(widget.accent),
          onChanged: onChanged),
    ]);
  }

  Widget _stat(String label, String value, Color accent) {
    return Expanded(
        child: Column(children: [
      Text(value,
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFFEEEEEE))),
      const SizedBox(height: 2),
      Text(label.toUpperCase(),
          style: TextStyle(
              fontSize: 9,
              color: Colors.grey[600],
              letterSpacing: 0.5,
              fontWeight: FontWeight.w600)),
    ]));
  }
}

// ─── Manual add / edit ───
class _ManualFoodSheet extends StatefulWidget {
  final Color accent;
  final FoodEntry? existing;
  final LabelParse? prefill; // from a scanned label, for a new entry
  final void Function(FoodEntry entry, double? servingGrams) onSave;
  final VoidCallback? onDelete;
  final VoidCallback? onMove;
  final VoidCallback? onCopy;
  final FoodEntry Function(String name, String serving, double cal, double p,
      double f, double c, Map<String, double> micros) buildEntry;
  const _ManualFoodSheet(
      {required this.accent,
      required this.existing,
      this.prefill,
      required this.onSave,
      required this.onDelete,
      required this.onMove,
      required this.onCopy,
      required this.buildEntry});
  @override
  State<_ManualFoodSheet> createState() => _ManualFoodSheetState();
}

class _ManualFoodSheetState extends State<_ManualFoodSheet> {
  late TextEditingController _name, _serving, _cal, _p, _f, _c, _fiber, _sodium;
  late TextEditingController _servingG;

  @override
  void initState() {
    super.initState();
    final FoodEntry? e = widget.existing;
    final LabelParse? pf = e == null ? widget.prefill : null;
    String num(double? v) => v == null ? '' : _trim(v, dp: 1);
    String servingSeed() {
      if (e != null) {
        return e.serving;
      }
      if (pf?.servingRaw != null && pf!.servingRaw!.isNotEmpty) {
        return pf.servingRaw!;
      }
      if (pf?.servingGrams != null) {
        return '${_trim(pf!.servingGrams!)} g';
      }
      return '';
    }

    _name = TextEditingController(text: e?.name ?? '');
    _serving = TextEditingController(text: servingSeed());
    _cal = TextEditingController(
        text: e != null ? _trim(e.calories) : num(pf?.calories));
    _p = TextEditingController(
        text: e != null ? _trim(e.protein) : num(pf?.protein));
    _f = TextEditingController(text: e != null ? _trim(e.fat) : num(pf?.fat));
    _c = TextEditingController(
        text: e != null ? _trim(e.carbs) : num(pf?.carbs));
    _fiber = TextEditingController(
        text: e != null && (e.nutrients['fiber'] ?? 0) > 0
            ? _trim(e.nutrients['fiber']!, dp: 1)
            : num(pf?.fiber));
    _sodium = TextEditingController(
        text: e != null && (e.nutrients['sodium'] ?? 0) > 0
            ? _trim(e.nutrients['sodium']!, dp: 1)
            : num(pf?.sodium));
    _servingG = TextEditingController(
        text: pf?.servingGrams != null ? num(pf!.servingGrams) : '');
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name, _serving, _cal, _p, _f, _c, _fiber, _sodium, _servingG
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ok =>
      _name.text.trim().isNotEmpty && (double.tryParse(_cal.text) ?? -1) >= 0;

  void _save() {
    // Preserve any micronutrients we don't expose as fields.
    final Map<String, double> micros =
        Map<String, double>.from(widget.existing?.nutrients ?? <String, double>{});
    // Sugars has no field of its own — keep what the label gave us.
    if (widget.existing == null && (widget.prefill?.sugars ?? 0) > 0) {
      micros['sugars'] = widget.prefill!.sugars!;
    }
    final double? fiber = double.tryParse(_fiber.text);
    final double? sodium = double.tryParse(_sodium.text);
    if (fiber != null && fiber > 0) {
      micros['fiber'] = fiber;
    } else {
      micros.remove('fiber');
    }
    if (sodium != null && sodium > 0) {
      micros['sodium'] = sodium;
    } else {
      micros.remove('sodium');
    }
    final double? servingGrams = double.tryParse(_servingG.text);
    widget.onSave(
      widget.buildEntry(
        _name.text.trim(),
        _serving.text.trim().isEmpty ? '1 serving' : _serving.text.trim(),
        double.tryParse(_cal.text) ?? 0,
        double.tryParse(_p.text) ?? 0,
        double.tryParse(_f.text) ?? 0,
        double.tryParse(_c.text) ?? 0,
        micros,
      ),
      (servingGrams != null && servingGrams > 0) ? servingGrams : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.existing != null ? 'Edit food' : 'Add food',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: widget.accent)),
              const SizedBox(height: 16),
              _field('NAME', _name, text: true),
              const SizedBox(height: 12),
              _field('SERVING (e.g. 1 cup, 100 g)', _serving, text: true),
              const SizedBox(height: 12),
              _field('WEIGHT OF ONE SERVING (g) — optional', _servingG),
              if (widget.existing == null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      'Add the weight and you can log any amount by grams — '
                      'calories and macros scale automatically.',
                      style:
                          TextStyle(color: Colors.grey[600], fontSize: 11)),
                ),
              const SizedBox(height: 12),
              Text('Nutrition per serving',
                  style: TextStyle(
                      color: widget.accent,
                      fontSize: 11,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              _field('CALORIES', _cal),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _field('PROTEIN (g)', _p)),
                const SizedBox(width: 10),
                Expanded(child: _field('FAT (g)', _f)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _field('CARBS (g)', _c)),
                const SizedBox(width: 10),
                Expanded(child: _field('FIBER (g)', _fiber)),
              ]),
              const SizedBox(height: 12),
              _field('SODIUM (mg)', _sodium),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                    child: SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _ok ? _save : null,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: widget.accent,
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: const Color(0xFF333333),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              textStyle: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          child: const Text('Save'),
                        ))),
                if (widget.onDelete != null) ...[
                  const SizedBox(width: 10),
                  IconButton(
                      onPressed: widget.onDelete,
                      icon: const Icon(Icons.delete_outline_rounded,
                          color: Color(0xFFCC5555))),
                ],
              ]),
              if (widget.onMove != null || widget.onCopy != null) ...[
                const SizedBox(height: 8),
                Row(children: [
                  if (widget.onMove != null)
                    Expanded(
                        child: TextButton.icon(
                      onPressed: widget.onMove,
                      icon: const Icon(Icons.event_rounded, size: 18),
                      label: const Text('Move to day'),
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.grey[400]),
                    )),
                  if (widget.onCopy != null)
                    Expanded(
                        child: TextButton.icon(
                      onPressed: widget.onCopy,
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy to day'),
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.grey[400]),
                    )),
                ]),
              ],
            ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController c, {bool text = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              letterSpacing: 1,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      TextField(
          controller: c,
          keyboardType: text
              ? TextInputType.text
              : const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 16, color: Color(0xFFEEEEEE)),
          decoration: _foodDec(widget.accent),
          onChanged: (_) => setState(() {})),
    ]);
  }
}

InputDecoration _foodDec(Color accent) {
  return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: const Color(0xFF111111),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF333333))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF333333))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accent)));
}

// ═══════════════════════════════════════════════════════════════════════
// MY FOODS — pick a saved food, choose a quantity, log it.
// ═══════════════════════════════════════════════════════════════════════

class _MyFoodsPage extends StatefulWidget {
  final Color accent;
  final List<CustomFood> foods;
  final void Function(List<CustomFood>) onSetFoods;
  final void Function(CustomFood food) onPick;
  const _MyFoodsPage(
      {required this.accent,
      required this.foods,
      required this.onSetFoods,
      required this.onPick});
  @override
  State<_MyFoodsPage> createState() => _MyFoodsPageState();
}

class _MyFoodsPageState extends State<_MyFoodsPage> {
  String _query = '';

  List<CustomFood> get _visible {
    final String q = _query.toLowerCase().trim();
    final List<CustomFood> list = widget.foods
        .where((CustomFood f) => !f.deleted)
        .where((CustomFood f) =>
            q.isEmpty || f.name.toLowerCase().contains(q))
        .toList();
    list.sort((CustomFood a, CustomFood b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  void _delete(CustomFood f) {
    // Tombstone so the deletion syncs to other devices.
    final CustomFood gone = f.copyWith(
        deleted: true,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch);
    widget.onSetFoods(
        CustomFoodStore.mergeFoods(widget.foods, <CustomFood>[gone]));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF2A2A2A),
        content: Text('Removed "${f.name}" from My Foods.')));
  }

  @override
  Widget build(BuildContext context) {
    final List<CustomFood> items = _visible;
    return Scaffold(
      backgroundColor: kBgDeep,
      appBar: AppBar(
          backgroundColor: kBgDeep,
          title: const Text('My Foods'),
          foregroundColor: const Color(0xFFEEEEEE)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            autofocus: false,
            style: const TextStyle(color: Color(0xFFEEEEEE)),
            onChanged: (String v) => setState(() => _query = v),
            decoration: _foodDec(widget.accent).copyWith(
                hintText: 'Search my foods',
                hintStyle: const TextStyle(color: Color(0xFF666666)),
                prefixIcon:
                    Icon(Icons.search_rounded, color: Colors.grey[600])),
          ),
        ),
        if (!CustomFoodStore.isConfigured)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
                'Sync is off — saved foods stay on this phone until the data token is set up.',
                style: TextStyle(color: Color(0xFF888866), fontSize: 12)),
          ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                      widget.foods.where((CustomFood f) => !f.deleted).isEmpty
                          ? 'No saved foods yet.\nScan a label or enter a food and it lands here automatically.'
                          : 'No matches.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFF777777), height: 1.5)),
                ))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: Color(0xFF1C1C1C)),
                  itemBuilder: (_, int i) {
                    final CustomFood f = items[i];
                    return Dismissible(
                      key: ValueKey<String>(f.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: const Color(0xFF3A1A1A),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete_outline_rounded,
                            color: Color(0xFFCC5555)),
                      ),
                      onDismissed: (_) => _delete(f),
                      child: ListTile(
                        title: Text(f.name,
                            style: const TextStyle(
                                color: Color(0xFFEEEEEE),
                                fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '${f.serving}  ·  ${_trim(f.calories)} cal  ·  '
                            'P${_trim(f.protein)} F${_trim(f.fat)} C${_trim(f.carbs)}',
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 12)),
                        trailing: Icon(Icons.add_circle_outline_rounded,
                            color: widget.accent),
                        onTap: () => widget.onPick(f),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// Quantity chooser for logging a saved food (returns servings, or null).
class _QuantitySheet extends StatefulWidget {
  final Color accent;
  final CustomFood food;
  const _QuantitySheet({required this.accent, required this.food});
  @override
  State<_QuantitySheet> createState() => _QuantitySheetState();
}

class _QuantitySheetState extends State<_QuantitySheet> {
  late TextEditingController _qty;
  @override
  void initState() {
    super.initState();
    _qty = TextEditingController(text: '1');
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  double get _q => double.tryParse(_qty.text) ?? 0;

  @override
  Widget build(BuildContext context) {
    final CustomFood f = widget.food;
    final double q = _q;
    final double? grams =
        f.servingGrams == null ? null : f.servingGrams! * q;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f.name,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: widget.accent)),
            const SizedBox(height: 4),
            Text('Per ${f.serving}: ${_trim(f.calories)} cal · '
                'P${_trim(f.protein)} F${_trim(f.fat)} C${_trim(f.carbs)}',
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const SizedBox(height: 16),
            Text('SERVINGS',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                    letterSpacing: 1,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Row(children: [
              _stepBtn(Icons.remove_rounded, () {
                final double v = (_q - 1).clamp(0, 9999).toDouble();
                _qty.text = _fmtQty(v);
                setState(() {});
              }),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _qty,
                  textAlign: TextAlign.center,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(
                      fontSize: 18, color: Color(0xFFEEEEEE)),
                  decoration: _foodDec(widget.accent),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              _stepBtn(Icons.add_rounded, () {
                _qty.text = _fmtQty(_q + 1);
                setState(() {});
              }),
            ]),
            const SizedBox(height: 10),
            Text(
                'Logs ${_trim(f.calories * q)} cal · '
                'P${_trim(f.protein * q)} F${_trim(f.fat * q)} C${_trim(f.carbs * q)}'
                '${grams != null ? ' · ${_trim(grams)} g' : ''}',
                style: TextStyle(color: Colors.grey[500], fontSize: 13)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: q > 0
                    ? () => Navigator.pop<double>(context, q)
                    : null,
                style: ElevatedButton.styleFrom(
                    backgroundColor: widget.accent,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: const Color(0xFF333333),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                child: const Text('Log it'),
              ),
            ),
          ]),
    );
  }

  String _fmtQty(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  Widget _stepBtn(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF333333))),
        child: Icon(icon, color: const Color(0xFFCCCCCC)),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// MEAL MAKER UI
// ═══════════════════════════════════════════════════════════════════════

String _newMealId() => DateTime.now().microsecondsSinceEpoch.toString();

// ─── Cook tab: cook a meal + 24h leftovers ───
class _CookScreen extends StatefulWidget {
  final Color accent;
  final List<Meal> meals;
  final void Function(List<Meal>) onSetMeals;
  final String logDate; // where logged portions land
  final void Function(FoodEntry) onLogFood;
  final bool embedded; // true when used as the Cook tab (don't pop the screen)
  const _CookScreen(
      {required this.accent,
      required this.meals,
      required this.onSetMeals,
      required this.logDate,
      required this.onLogFood,
      this.embedded = false});
  @override
  State<_CookScreen> createState() => _CookScreenState();
}

class _CookScreenState extends State<_CookScreen> {
  late List<Meal> _meals;

  @override
  void initState() {
    super.initState();
    _meals = List<Meal>.from(widget.meals);
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  List<Meal> get _active {
    final List<Meal> a = _meals.where((Meal m) => m.isActive(_now)).toList();
    a.sort((Meal x, Meal y) => y.createdAtMs.compareTo(x.createdAtMs));
    return a;
  }

  void _persist() => widget.onSetMeals(_meals);

  String _nowTime() {
    final DateTime n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _cookNew() async {
    final Meal? m = await Navigator.of(context).push<Meal>(
        MaterialPageRoute<Meal>(
            builder: (_) =>
                _MealEditScreen(accent: widget.accent, existing: null)));
    if (m == null || m.ingredients.isEmpty || !mounted) {
      return;
    }
    // Keep only still-active leftovers, then add the fresh dish.
    setState(() => _meals = <Meal>[
          ..._meals.where((Meal x) => x.isActive(_now)),
          m,
        ]);
    _persist();
    _portion(m); // straight to "how much do I eat?"
  }

  Future<void> _editMeal(Meal meal) async {
    final Meal? m = await Navigator.of(context).push<Meal>(
        MaterialPageRoute<Meal>(
            builder: (_) =>
                _MealEditScreen(accent: widget.accent, existing: meal)));
    if (m != null) {
      setState(() =>
          _meals = _meals.map((Meal x) => x.id == m.id ? m : x).toList());
      _persist();
    }
  }

  void _deleteMeal(Meal meal) {
    setState(() => _meals = _meals.where((Meal x) => x.id != meal.id).toList());
    _persist();
  }

  void _portion(Meal meal) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _MealPortionSheet(
        meal: meal,
        accent: widget.accent,
        onLog: (MealPortion portion) {
          final ScaffoldMessengerState messenger =
              ScaffoldMessenger.of(context);
          widget.onLogFood(MealMath.toEntry(meal, portion,
              id: _newMealId(), date: widget.logDate, time: _nowTime()));
          Navigator.pop(context); // close sheet
          if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context); // back to the food day view
          }
          messenger.showSnackBar(SnackBar(
              backgroundColor: const Color(0xFF2A2A2A),
              content: Text(
                  'Logged ${portion.calories.round()} cal from ${meal.name}.')));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Meal> active = _active;
    return Scaffold(
      backgroundColor: kBgDeep,
      appBar: AppBar(
          backgroundColor: kBgDeep,
          foregroundColor: const Color(0xFFEEEEEE),
          title: const Text('Cook')),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _cookNew,
          backgroundColor: widget.accent,
          foregroundColor: Colors.black,
          icon: const Icon(Icons.outdoor_grill_rounded),
          label: const Text('COOK A MEAL',
              style: TextStyle(fontWeight: FontWeight.w800))),
      body: active.isEmpty
          ? Center(
              child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                      'No meals cooking.\n\nTap COOK A MEAL, add your raw ingredients, and it tells you how many grams of the cooked food to eat for your calorie target.\n\nMeals stay here for 24 hours so you can grab another portion.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 14, color: Colors.grey[600], height: 1.6))))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('LEFTOVERS (next 24h)',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                          letterSpacing: 1,
                          fontWeight: FontWeight.w600)),
                ),
                ...active.map((Meal m) {
                  final int hLeft = (24 -
                          (_now - m.createdAtMs) / (60 * 60 * 1000))
                      .ceil();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: kSurface0,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _portion(m),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: kBorder)),
                          child: Row(children: <Widget>[
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(m.name,
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFFDDDDDD))),
                                    const SizedBox(height: 3),
                                    Text(
                                        '${m.calories.round()} cal · ~${m.cookedTotalGrams.round()} g cooked · ${hLeft}h left',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey[600])),
                                  ]),
                            ),
                            IconButton(
                                onPressed: () => _editMeal(m),
                                icon: const Icon(Icons.edit_rounded,
                                    size: 18, color: Color(0xFF888888))),
                            IconButton(
                                onPressed: () => _deleteMeal(m),
                                icon: const Icon(Icons.delete_outline_rounded,
                                    size: 18, color: Color(0xFFCC5555))),
                          ]),
                        ),
                      ),
                    ),
                  );
                }),
              ]),
    );
  }
}

// ─── Create / edit a meal ───
class _MealEditScreen extends StatefulWidget {
  final Color accent;
  final Meal? existing;
  const _MealEditScreen({required this.accent, required this.existing});
  @override
  State<_MealEditScreen> createState() => _MealEditScreenState();
}

class _MealEditScreenState extends State<_MealEditScreen> {
  late TextEditingController _name;
  late List<MealIngredient> _ings;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _ings = List<MealIngredient>.from(
        widget.existing?.ingredients ?? <MealIngredient>[]);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ok => _name.text.trim().isNotEmpty && _ings.isNotEmpty;

  Meal get _meal => Meal(
      id: widget.existing?.id ?? _newMealId(),
      name: _name.text.trim(),
      ingredients: _ings,
      createdAtMs: widget.existing?.createdAtMs ??
          DateTime.now().millisecondsSinceEpoch);

  void _addTemplate(FoodTemplate t) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ConfirmFoodSheet(
        template: t,
        accent: widget.accent,
        onSave: (double grams, String _) {
          setState(() =>
              _ings = <MealIngredient>[..._ings, MealIngredient(food: t, rawGrams: grams)]);
          Navigator.pop(context);
        },
      ),
    );
  }

  Future<void> _scan() async {
    final String? code = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
            builder: (_) => _ScannerPage(accent: widget.accent)));
    if (code == null || !mounted) {
      return;
    }
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Center(child: CircularProgressIndicator(color: widget.accent)));
    FoodTemplate? t;
    try {
      t = await FoodLookup.barcode(code);
    } catch (_) {}
    if (!mounted) {
      return;
    }
    Navigator.pop(context);
    if (t == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: Color(0xFF2A2A2A),
          content: Text('Not found — add it manually.')));
      return;
    }
    _addTemplate(t);
  }

  Future<void> _search() async {
    final FoodTemplate? t = await Navigator.of(context).push<FoodTemplate>(
        MaterialPageRoute<FoodTemplate>(
            builder: (_) => _FoodSearchPage(accent: widget.accent)));
    if (t != null && mounted) {
      _addTemplate(t);
    }
  }

  void _manual() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ManualIngredientSheet(
        accent: widget.accent,
        onSave: (MealIngredient ing) {
          setState(() => _ings = <MealIngredient>[..._ings, ing]);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _addIngredient() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        const SizedBox(height: 8),
        _ingTile(Icons.qr_code_scanner_rounded, 'Scan barcode', () {
          Navigator.pop(context);
          _scan();
        }),
        _ingTile(Icons.search_rounded, 'Search by name', () {
          Navigator.pop(context);
          _search();
        }),
        _ingTile(Icons.edit_rounded, 'Enter manually', () {
          Navigator.pop(context);
          _manual();
        }),
        const SizedBox(height: 8),
      ])),
    );
  }

  Widget _ingTile(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: widget.accent),
      title: Text(title,
          style: const TextStyle(
              color: Color(0xFFEEEEEE), fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }

  Future<void> _editIngredient(int index) async {
    final MealIngredient ing = _ings[index];
    final TextEditingController g =
        TextEditingController(text: _trim(ing.rawGrams, dp: 1));
    final TextEditingController y =
        TextEditingController(text: _trim(ing.yieldFactor, dp: 2));
    final MealIngredient? result =
        await showModalBottomSheet<MealIngredient>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(
          builder: (BuildContext ctx, void Function(void Function()) setSheet) {
        final double raw = double.tryParse(g.text) ?? 0;
        final double yf = double.tryParse(y.text) ?? 1;
        return Padding(
          padding: EdgeInsets.fromLTRB(
              24,
              20,
              24,
              MediaQuery.of(ctx).viewInsets.bottom +
                  MediaQuery.of(ctx).viewPadding.bottom +
                  24),
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Text(ing.food.name,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: widget.accent)),
            const SizedBox(height: 12),
            Row(children: <Widget>[
              Expanded(
                  child: TextField(
                      controller: g,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      style: const TextStyle(
                          fontSize: 16, color: Color(0xFFEEEEEE)),
                      decoration: _foodDec(widget.accent)
                          .copyWith(labelText: 'Raw grams'),
                      onChanged: (_) => setSheet(() {}))),
              const SizedBox(width: 10),
              Expanded(
                  child: TextField(
                      controller: y,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      style: const TextStyle(
                          fontSize: 16, color: Color(0xFFEEEEEE)),
                      decoration: _foodDec(widget.accent)
                          .copyWith(labelText: 'Cook yield ×'),
                      onChanged: (_) => setSheet(() {}))),
            ]),
            const SizedBox(height: 10),
            Text('Cooked ≈ ${(raw * yf).round()} g',
                style: TextStyle(fontSize: 13, color: Colors.grey[500])),
            const SizedBox(height: 16),
            SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                    onPressed: () => Navigator.pop(
                        ctx,
                        ing.copyWith(
                            rawGrams: double.tryParse(g.text),
                            yieldFactor: double.tryParse(y.text))),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: widget.accent,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12))),
                    child: const Text('Update'))),
          ]),
        );
      }),
    );
    if (result != null && result.rawGrams > 0) {
      setState(() => _ings[index] = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Meal preview = Meal(id: 'x', name: '', ingredients: _ings);
    return Scaffold(
      backgroundColor: kBgDeep,
      appBar: AppBar(
        backgroundColor: kBgDeep,
        foregroundColor: const Color(0xFFEEEEEE),
        title: Text(widget.existing != null ? 'Edit meal' : 'New meal'),
        actions: <Widget>[
          TextButton(
            onPressed: _ok ? () => Navigator.pop(context, _meal) : null,
            child: Text('Save',
                style: TextStyle(
                    color: _ok ? widget.accent : const Color(0xFF555555),
                    fontWeight: FontWeight.w800,
                    fontSize: 15)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          TextField(
              controller: _name,
              style: const TextStyle(fontSize: 16, color: Color(0xFFEEEEEE)),
              decoration: _foodDec(widget.accent)
                  .copyWith(hintText: 'Meal name (e.g. Chili batch)'),
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 14),
          if (_ings.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: kSurface1,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder)),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: <Widget>[
                    _tot('Total', '${preview.calories.round()}', 'cal'),
                    _tot('Cooked', '${preview.cookedTotalGrams.round()}', 'g'),
                    _tot('Protein', _trim(preview.protein), 'g'),
                    _tot('Carbs', _trim(preview.carbs), 'g'),
                  ]),
            ),
          const SizedBox(height: 8),
          ..._ings.asMap().entries.map((MapEntry<int, MealIngredient> e) {
            final MealIngredient ing = e.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: kSurface0,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _editIngredient(e.key),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 11),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kBorder)),
                    child: Row(children: <Widget>[
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(ing.food.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 14, color: Color(0xFFDDDDDD))),
                                Text(
                                    '${_trim(ing.rawGrams)} g raw → ${ing.cookedGrams.round()} g cooked',
                                    style: TextStyle(
                                        fontSize: 11, color: Colors.grey[600])),
                              ])),
                      Text('${ing.calories.round()} cal',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: widget.accent)),
                      IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              setState(() => _ings.removeAt(e.key)),
                          icon: const Icon(Icons.close_rounded,
                              size: 16, color: Color(0xFF888888))),
                    ]),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addIngredient,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add ingredient'),
            style: OutlinedButton.styleFrom(
                foregroundColor: widget.accent,
                side: BorderSide(
                    color: Color.fromRGBO(widget.accent.red, widget.accent.green,
                        widget.accent.blue, 0.4)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
          ),
        ],
      ),
    );
  }

  Widget _tot(String label, String value, String unit) {
    return Column(children: <Widget>[
      Text(value,
          style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFFEEEEEE))),
      Text('$label ($unit)',
          style: TextStyle(
              fontSize: 9,
              color: Colors.grey[600],
              letterSpacing: 0.3,
              fontWeight: FontWeight.w600)),
    ]);
  }
}

// ─── Portion a meal by calories or grams, then log it ───
class _MealPortionSheet extends StatefulWidget {
  final Meal meal;
  final Color accent;
  final void Function(MealPortion) onLog;
  const _MealPortionSheet(
      {required this.meal, required this.accent, required this.onLog});
  @override
  State<_MealPortionSheet> createState() => _MealPortionSheetState();
}

class _MealPortionSheetState extends State<_MealPortionSheet> {
  late TextEditingController _amount;
  bool _byCalories = true;

  @override
  void initState() {
    super.initState();
    _amount =
        TextEditingController(text: '${widget.meal.calories.round()}');
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double get _val => double.tryParse(_amount.text) ?? 0;

  MealPortion get _portion => _byCalories
      ? MealMath.byCalories(widget.meal, _val)
      : MealMath.byCookedGrams(widget.meal, _val);

  void _setMode(bool byCal) {
    setState(() {
      _byCalories = byCal;
      _amount.text = byCal
          ? '${widget.meal.calories.round()}'
          : '${widget.meal.cookedTotalGrams.round()}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final MealPortion p = _portion;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(widget.meal.name,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: widget.accent)),
              const SizedBox(height: 4),
              Text(
                  'Whole dish: ${widget.meal.calories.round()} cal · ~${widget.meal.cookedTotalGrams.round()} g cooked',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const SizedBox(height: 16),
              Row(children: <Widget>[
                _modeChip('By calories', _byCalories, () => _setMode(true)),
                const SizedBox(width: 8),
                _modeChip('By cooked grams', !_byCalories, () => _setMode(false)),
              ]),
              const SizedBox(height: 12),
              Text(_byCalories ? 'CALORIES TO EAT' : 'COOKED GRAMS TO EAT',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 17, color: Color(0xFFEEEEEE)),
                  decoration: _foodDec(widget.accent),
                  onChanged: (_) => setState(() {})),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: kSurface1,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kBorder)),
                child: Column(children: <Widget>[
                  Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: <Widget>[
                    _stat(_byCalories ? 'Weigh out' : 'Calories',
                        _byCalories ? '${p.grams.round()} g' : '${p.calories.round()}',
                        widget.accent),
                    _stat('Protein', '${_trim(p.protein)} g', widget.accent),
                    _stat('Fat', '${_trim(p.fat)} g', widget.accent),
                    _stat('Carbs', '${_trim(p.carbs)} g', widget.accent),
                  ]),
                  if (p.breakdown.isNotEmpty) ...<Widget>[
                    const Divider(color: Color(0xFF262626), height: 22),
                    Text('PER INGREDIENT (cooked, this portion)',
                        style: TextStyle(
                            fontSize: 9,
                            color: Colors.grey[600],
                            letterSpacing: 0.5,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    ...p.breakdown.map((IngredientPortion ip) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: <Widget>[
                                Expanded(
                                    child: Text(ip.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: Colors.grey[400]))),
                                Text('${_trim(ip.grams)} g',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFDDDDDD))),
                              ]),
                        )),
                  ],
                ]),
              ),
              const SizedBox(height: 18),
              SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed:
                        _val > 0 ? () => widget.onLog(_portion) : null,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: widget.accent,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor: const Color(0xFF333333),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    child: const Text('Log this portion'),
                  )),
            ]),
      ),
    );
  }

  Widget _modeChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
            color: active ? widget.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: active ? widget.accent : const Color(0xFF333333))),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: active ? Colors.black : Colors.grey[500])),
      ),
    );
  }

  Widget _stat(String label, String value, Color accent) {
    return Column(children: <Widget>[
      Text(value,
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFFEEEEEE))),
      const SizedBox(height: 2),
      Text(label.toUpperCase(),
          style: TextStyle(
              fontSize: 9,
              color: Colors.grey[600],
              letterSpacing: 0.5,
              fontWeight: FontWeight.w600)),
    ]);
  }
}

// ─── Manual ingredient (nutrition entered for the raw grams) ───
class _ManualIngredientSheet extends StatefulWidget {
  final Color accent;
  final void Function(MealIngredient) onSave;
  const _ManualIngredientSheet({required this.accent, required this.onSave});
  @override
  State<_ManualIngredientSheet> createState() => _ManualIngredientSheetState();
}

class _ManualIngredientSheetState extends State<_ManualIngredientSheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _grams = TextEditingController();
  final TextEditingController _cal = TextEditingController();
  final TextEditingController _p = TextEditingController();
  final TextEditingController _f = TextEditingController();
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    for (final TextEditingController x in <TextEditingController>[
      _name, _grams, _cal, _p, _f, _c
    ]) {
      x.dispose();
    }
    super.dispose();
  }

  bool get _ok =>
      _name.text.trim().isNotEmpty &&
      (double.tryParse(_grams.text) ?? 0) > 0 &&
      (double.tryParse(_cal.text) ?? -1) >= 0;

  void _save() {
    final double grams = double.parse(_grams.text);
    final double per100 = 100.0 / grams; // scale absolute → per-100g
    final FoodTemplate t = FoodTemplate(
      name: _name.text.trim(),
      kcal100: (double.tryParse(_cal.text) ?? 0) * per100,
      protein100: (double.tryParse(_p.text) ?? 0) * per100,
      fat100: (double.tryParse(_f.text) ?? 0) * per100,
      carbs100: (double.tryParse(_c.text) ?? 0) * per100,
      nutrients100: <String, double>{},
    );
    widget.onSave(MealIngredient(food: t, rawGrams: grams));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Manual ingredient',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: widget.accent)),
              const SizedBox(height: 4),
              Text('Enter the nutrition for the raw amount you\'re adding.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const SizedBox(height: 16),
              _field('NAME', _name, text: true),
              const SizedBox(height: 12),
              _field('RAW GRAMS', _grams),
              const SizedBox(height: 12),
              _field('CALORIES (for that amount)', _cal),
              const SizedBox(height: 12),
              Row(children: <Widget>[
                Expanded(child: _field('PROTEIN (g)', _p)),
                const SizedBox(width: 10),
                Expanded(child: _field('FAT (g)', _f)),
              ]),
              const SizedBox(height: 12),
              _field('CARBS (g)', _c),
              const SizedBox(height: 18),
              SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _ok ? _save : null,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: widget.accent,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor: const Color(0xFF333333),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    child: const Text('Add ingredient'),
                  )),
            ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController c, {bool text = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(label,
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              letterSpacing: 1,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      TextField(
          controller: c,
          keyboardType: text
              ? TextInputType.text
              : const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 16, color: Color(0xFFEEEEEE)),
          decoration: _foodDec(widget.accent),
          onChanged: (_) => setState(() {})),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SCROLL TIME PICKER  (hours + minutes wheels on one page)
// ═══════════════════════════════════════════════════════════════════════

/// Shows hour + minute scroll wheels. Returns 'HH:mm' or null if cancelled.
Future<String?> showScrollTime(
    BuildContext context, Color accent, String initial) {
  final List<String> hm =
      initial.contains(':') ? initial.split(':') : <String>['12', '0'];
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: kSurface2,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _ScrollTimeSheet(
        accent: accent,
        initialHour: int.tryParse(hm[0]) ?? 12,
        initialMinute: int.tryParse(hm[1]) ?? 0),
  );
}

class _ScrollTimeSheet extends StatefulWidget {
  final Color accent;
  final int initialHour;
  final int initialMinute;
  const _ScrollTimeSheet(
      {required this.accent,
      required this.initialHour,
      required this.initialMinute});
  @override
  State<_ScrollTimeSheet> createState() => _ScrollTimeSheetState();
}

class _ScrollTimeSheetState extends State<_ScrollTimeSheet> {
  late int _hour;
  late int _minute;

  @override
  void initState() {
    super.initState();
    _hour = widget.initialHour;
    _minute = widget.initialMinute;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Text('SELECT TIME',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: Row(children: <Widget>[
              Expanded(child: _wheel(24, _hour, (int v) => _hour = v, 'h')),
              Text(':',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: widget.accent)),
              Expanded(
                  child: _wheel(60, _minute, (int v) => _minute = v, 'm')),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(
                  context,
                  '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: widget.accent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  textStyle:
                      const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              child: const Text('Done'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _wheel(
      int count, int initial, void Function(int) onChange, String suffix) {
    return CupertinoPicker(
      scrollController: FixedExtentScrollController(initialItem: initial),
      itemExtent: 40,
      magnification: 1.1,
      squeeze: 1.1,
      backgroundColor: Colors.transparent,
      selectionOverlay: Container(
        decoration: BoxDecoration(
            border: Border.symmetric(
                horizontal: BorderSide(
                    color: Color.fromRGBO(widget.accent.red, widget.accent.green,
                        widget.accent.blue, 0.4)))),
      ),
      onSelectedItemChanged: onChange,
      children: List<Widget>.generate(
          count,
          (int i) => Center(
              child: Text('${i.toString().padLeft(2, '0')}$suffix',
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFEEEEEE))))),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// FOOD ADVISOR UI
// ═══════════════════════════════════════════════════════════════════════

String _agoLabel(int ms) {
  if (ms == 0) {
    return '';
  }
  final int mins =
      (DateTime.now().millisecondsSinceEpoch - ms) ~/ 60000;
  if (mins < 1) {
    return 'just now';
  }
  if (mins < 60) {
    return '${mins}m ago';
  }
  final int h = mins ~/ 60;
  if (h < 24) {
    return '${h}h ago';
  }
  return '${h ~/ 24}d ago';
}

class _AdvisorCard extends StatefulWidget {
  final UserCalibration cal;
  final List<DailyLog> logs;
  final List<FoodEntry> foods;
  final List<String> fasted;
  final List<SleepEntry> sleep;
  final List<RunRecord> runs;
  final int trainerLevel;
  final List<AdvisorInsight> insights;
  final void Function(List<AdvisorInsight>) onSetInsights;
  final Color accent;
  const _AdvisorCard(
      {required this.cal,
      required this.logs,
      required this.foods,
      required this.fasted,
      required this.sleep,
      required this.runs,
      required this.trainerLevel,
      required this.insights,
      required this.onSetInsights,
      required this.accent});
  @override
  State<_AdvisorCard> createState() => _AdvisorCardState();
}

class _AdvisorCardState extends State<_AdvisorCard> {
  String? _busyKind;
  String? _error;

  String get _todayKey => formatDate(DateTime.now());
  String get _weekKey {
    final DateTime n = DateTime.now();
    return formatDate(n.subtract(Duration(days: n.weekday - 1)));
  }

  AdvisorInsight? _latest(String kind) {
    final List<AdvisorInsight> m =
        widget.insights.where((AdvisorInsight i) => i.kind == kind).toList();
    return m.isEmpty ? null : m.last;
  }

  Future<void> _generate(String kind) async {
    setState(() {
      _busyKind = kind;
      _error = null;
    });
    try {
      final String digest = AdvisorDigest.build(
          widget.cal, widget.logs, widget.foods, widget.fasted.toSet(), kind,
          sleep: widget.sleep,
          runs: widget.runs,
          trainerLevel: widget.trainerLevel);
      final String text = await Advisor.generate(
          model: widget.cal.advisorModel, kind: kind, digest: digest);
      if (!mounted) {
        return;
      }
      final String key = kind == 'weekly' ? _weekKey : _todayKey;
      final List<AdvisorInsight> updated = widget.insights
          .where((AdvisorInsight i) => i.kind != kind)
          .toList()
        ..add(AdvisorInsight(
            kind: kind,
            periodKey: key,
            text: text,
            createdAtMs: DateTime.now().millisecondsSinceEpoch));
      widget.onSetInsights(updated);
    } on AdvisorException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Something went wrong reaching the coach.');
      }
    } finally {
      if (mounted) {
        setState(() => _busyKind = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = widget.accent;
    final AdvisorInsight? daily = _latest('daily');
    final AdvisorInsight? weekly = _latest('weekly');
    final bool todayDone = daily != null && daily.periodKey == _todayKey;
    final bool weekDone = weekly != null && weekly.periodKey == _weekKey;
    final bool configured = Advisor.configured;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[
          Row(children: <Widget>[
            Icon(Icons.psychology_rounded, size: 16, color: accent),
            const SizedBox(width: 6),
            Text('COACH',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[500],
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700)),
          ]),
          Text(advisorModelLabel(widget.cal.advisorModel),
              style: TextStyle(fontSize: 10, color: Colors.grey[600])),
        ]),
        const SizedBox(height: 10),
        if (!configured)
          Text(
              'AI coach isn\'t set up in this build (no API key). Add one to enable coaching.',
              style: TextStyle(
                  fontSize: 13, color: Colors.grey[500], height: 1.4))
        else ...<Widget>[
          if (daily != null)
            InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => _AdvisorDetailScreen(
                      daily: daily, weekly: weekly, accent: accent))),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(daily.text,
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5,
                            color: Color(0xFFDDDDDD),
                            height: 1.5)),
                    const SizedBox(height: 4),
                    Text('tap to read in full · ${_agoLabel(daily.createdAtMs)}',
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey[600])),
                  ]),
            )
          else
            Text('No coaching yet today. Tap below for a check-in.',
                style: TextStyle(fontSize: 13, color: Colors.grey[500])),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFCC8855))),
          ],
          const SizedBox(height: 12),
          Row(children: <Widget>[
            Expanded(
                child: _coachBtn(
                    label: todayDone ? "Today's coaching ✓" : "Today's coaching",
                    busy: _busyKind == 'daily',
                    enabled: !todayDone && _busyKind == null,
                    onTap: () => _generate('daily'),
                    accent: accent,
                    filled: true)),
            const SizedBox(width: 10),
            Expanded(
                child: _coachBtn(
                    label: weekDone ? 'Weekly ✓' : 'Weekly review',
                    busy: _busyKind == 'weekly',
                    enabled: !weekDone && _busyKind == null,
                    onTap: () => _generate('weekly'),
                    accent: accent,
                    filled: false)),
          ]),
        ],
      ]),
    );
  }

  Widget _coachBtn(
      {required String label,
      required bool busy,
      required bool enabled,
      required VoidCallback onTap,
      required Color accent,
      required bool filled}) {
    final Widget child = busy
        ? SizedBox(
            height: 16,
            width: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2,
                color: filled ? Colors.black : accent))
        : Text(label,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: !enabled
                    ? Colors.grey[600]
                    : (filled ? Colors.black : accent)));
    return SizedBox(
      height: 42,
      child: filled
          ? ElevatedButton(
              onPressed: enabled ? onTap : null,
              style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  disabledBackgroundColor: const Color(0xFF2A2A2A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: child)
          : OutlinedButton(
              onPressed: enabled ? onTap : null,
              style: OutlinedButton.styleFrom(
                  side: BorderSide(
                      color: enabled
                          ? Color.fromRGBO(
                              accent.red, accent.green, accent.blue, 0.4)
                          : const Color(0xFF2A2A2A)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: child),
    );
  }
}

class _AdvisorDetailScreen extends StatelessWidget {
  final AdvisorInsight? daily;
  final AdvisorInsight? weekly;
  final Color accent;
  const _AdvisorDetailScreen(
      {required this.daily, required this.weekly, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgDeep,
      appBar: AppBar(
          backgroundColor: kBgDeep,
          foregroundColor: const Color(0xFFEEEEEE),
          title: const Text('Coach')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          if (daily != null) _section('TODAY', daily!, accent),
          if (weekly != null) _section('THIS WEEK', weekly!, accent),
          if (daily == null && weekly == null)
            Padding(
                padding: const EdgeInsets.all(32),
                child: Text('No coaching yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[600]))),
        ],
      ),
    );
  }

  Widget _section(String title, AdvisorInsight i, Color accent) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[
          Text(title,
              style: TextStyle(
                  fontSize: 11,
                  color: accent,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700)),
          Text(_agoLabel(i.createdAtMs),
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ]),
        const SizedBox(height: 10),
        SelectableText(i.text,
            style: const TextStyle(
                fontSize: 14, color: Color(0xFFDDDDDD), height: 1.6)),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 5K TRAINER UI
//
// Today's workout off the adaptive ladder, an in-run coach that cues
// run/walk with vibration + optional speech, manual + Health Connect run
// logging, and the run history. The plan rung advances/repeats based on how
// each run actually went (see trainer.dart). A light fueling flag ties run
// volume to the calorie deficit.
// ═══════════════════════════════════════════════════════════════════════

String _newRunId() => 'run_${DateTime.now().microsecondsSinceEpoch}';

double _kmToMi(double km) => km * 0.621371;

class TrainScreen extends StatefulWidget {
  final Color accent;
  final UserCalibration cal;
  final List<DailyLog> logs;
  final List<RunRecord> runs;
  final TrainerState trainer;
  final List<SleepEntry> sleep;
  final void Function(List<RunRecord>) onSetRuns;
  final void Function(TrainerState) onSetTrainer;
  const TrainScreen(
      {super.key,
      required this.accent,
      required this.cal,
      required this.logs,
      required this.runs,
      required this.trainer,
      required this.sleep,
      required this.onSetRuns,
      required this.onSetTrainer});
  @override
  State<TrainScreen> createState() => _TrainScreenState();
}

class _TrainScreenState extends State<TrainScreen> {
  Workout get _today => workoutForLevel(widget.trainer.level);
  String? _coachText;
  bool _coaching = false;

  // ── AI coaching (reuses the Claude client behind the Food Advisor) ───
  String _runDigest() {
    final StringBuffer b = StringBuffer();
    final Workout w = _today;
    b.writeln('Plan: Level ${w.level} of $kMaxLevel — "${w.name}".');
    final List<RunRecord> recent = widget.runs.reversed.take(8).toList();
    if (recent.isEmpty) {
      b.writeln('No runs logged yet.');
    } else {
      b.writeln('Recent runs (newest first):');
      for (final RunRecord r in recent) {
        final String dist = r.distanceKm > 0
            ? '${_kmToMi(r.distanceKm).toStringAsFixed(2)} mi, '
                '${_paceMinPerMile(r)} /mi'
            : 'no distance';
        b.writeln('- ${r.date}: ${(r.durationSec / 60).round()} min, $dist'
            '${r.avgHr != null ? ', HR ${r.avgHr!.round()}' : ''}'
            ', felt ${r.effort}${r.completed ? '' : ', PARTIAL'}');
      }
    }
    if (widget.logs.isNotEmpty) {
      b.writeln('Latest weight: '
          '${widget.logs.last.weight.toStringAsFixed(1)} lb.');
    }
    b.writeln('Planned daily calorie deficit: ${widget.cal.deficit} kcal.');
    b.writeln('Runs in the last 7 days: '
        '${runsThisWeek(widget.runs, DateTime.now())}.');
    final String sleep = sleepDigest(widget.sleep, DateTime.now());
    if (sleep.isNotEmpty) {
      b.writeln(sleep);
    }
    return b.toString();
  }

  double? get _lastNightHours => SleepMath.latest(widget.sleep)?.hours;
  double? get _baselineHours =>
      SleepMath.baselineHours(widget.sleep, DateTime.now());

  Future<void> _askCoach() async {
    setState(() => _coaching = true);
    try {
      final String text = await Advisor.generate(
          model: widget.cal.advisorModel, kind: 'run', digest: _runDigest());
      if (mounted) {
        setState(() => _coachText = text);
      }
    } on AdvisorException catch (e) {
      if (mounted) {
        setState(() => _coachText = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _coachText = 'Coaching is unavailable right now.');
      }
    } finally {
      if (mounted) {
        setState(() => _coaching = false);
      }
    }
  }

  String _fmtMin(int seconds) {
    final int m = seconds ~/ 60;
    final int s = seconds % 60;
    return s == 0 ? '${m}m' : '${m}m ${s}s';
  }

  // ── Record a finished run and adapt the ladder ──────────────────────
  void _recordRun(RunRecord r, {required bool advance}) {
    final int before = widget.trainer.level;
    final int after =
        advance ? nextLevel(before, r.outcome) : before;
    widget.onSetRuns(<RunRecord>[...widget.runs, r]);
    if (after != before) {
      widget.onSetTrainer(widget.trainer.copyWith(level: after));
    }
    if (!mounted) {
      return;
    }
    final String msg = !r.completed
        ? 'Run saved. Same workout next time — no rush.'
        : (after != before ? 'Nice. Leveled up to your next workout.' : 'Run logged.');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF2A2A2A), content: Text(msg)));
  }

  // ── Calibration ─────────────────────────────────────────────────────
  Future<void> _calibrate() async {
    final double? minutes = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _CalibrationSheet(accent: widget.accent),
    );
    if (minutes == null || !mounted) {
      return;
    }
    final int lvl = startingLevel(minutes);
    widget.onSetTrainer(
        widget.trainer.copyWith(level: lvl, calibrated: true));
  }

  // ── Coached run ─────────────────────────────────────────────────────
  Future<void> _startCoach() async {
    final RunOutcome? outcome = await Navigator.of(context).push<RunOutcome>(
        MaterialPageRoute<RunOutcome>(
            fullscreenDialog: true,
            builder: (_) => _CoachScreen(
                workout: _today,
                accent: widget.accent,
                audioCues: widget.trainer.audioCues)));
    if (outcome == null || !mounted) {
      return; // stopped early & discarded
    }
    _recordRun(
      RunRecord(
        id: _newRunId(),
        date: formatDate(DateTime.now()),
        level: _today.level,
        distanceKm: 0,
        durationSec: _today.totalSeconds,
        source: 'manual',
        completed: outcome.completed,
        effort: outcome.effort.name,
      ),
      advance: outcome.completed,
    );
  }

  // ── Manual entry ────────────────────────────────────────────────────
  Future<void> _logManual() async {
    final RunRecord? r = await showModalBottomSheet<RunRecord>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ManualRunSheet(accent: widget.accent, level: _today.level),
    );
    if (r == null || !mounted) {
      return;
    }
    _recordRun(r, advance: r.completed && r.level == _today.level);
  }

  // ── Health Connect import ───────────────────────────────────────────
  Future<void> _importHealthConnect() async {
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            Center(child: CircularProgressIndicator(color: widget.accent)));
    final List<_WorkoutOpt> opts = <_WorkoutOpt>[];
    // Diagnostics so a blind failure can still be understood from the phone.
    bool granted = false;
    int rawWorkouts = 0;
    int hrCount = 0, stepCount = 0, distCount = 0;
    String? exception;
    try {
      final Health health = Health();
      await health.configure();
      // Ask for exercise (workout) read on its own — do NOT couple it to
      // heart-rate, so a HR permission gap can't wipe the workout results.
      // Request read for workouts, heart rate, distance, and steps — distance
      // is what lets us reconstruct a run when the workout-session read fails.
      final List<HealthDataType> reqTypes = <HealthDataType>[
        HealthDataType.WORKOUT,
        HealthDataType.HEART_RATE,
        HealthDataType.DISTANCE_DELTA,
        HealthDataType.STEPS,
        HealthDataType.ACTIVE_ENERGY_BURNED,
      ];
      granted = await health.requestAuthorization(reqTypes,
          permissions:
              reqTypes.map((_) => HealthDataAccess.READ).toList());

      final DateTime now = DateTime.now();
      final DateTime start = now.subtract(const Duration(days: 7));
      // Query workouts ALONE.
      final List<HealthDataPoint> workouts =
          await health.getHealthDataFromTypes(
              startTime: start,
              endTime: now,
              types: <HealthDataType>[HealthDataType.WORKOUT]);
      rawWorkouts = workouts.length;
      // Heart rate is best-effort and must never block the import.
      List<HealthDataPoint> hrPts = <HealthDataPoint>[];
      try {
        hrPts = await health.getHealthDataFromTypes(
            startTime: start,
            endTime: now,
            types: <HealthDataType>[HealthDataType.HEART_RATE]);
      } catch (_) {}
      hrCount = hrPts.length;
      // Diagnostic probes: what OTHER exercise-adjacent data is readable?
      try {
        stepCount = (await health.getHealthDataFromTypes(
                startTime: start,
                endTime: now,
                types: <HealthDataType>[HealthDataType.STEPS]))
            .length;
      } catch (_) {}
      List<HealthDataPoint> distPts = <HealthDataPoint>[];
      try {
        distPts = await health.getHealthDataFromTypes(
            startTime: start,
            endTime: now,
            types: <HealthDataType>[HealthDataType.DISTANCE_DELTA]);
      } catch (_) {}
      distCount = distPts.length;
      List<HealthDataPoint> calPts = <HealthDataPoint>[];
      try {
        calPts = await health.getHealthDataFromTypes(
            startTime: start,
            endTime: now,
            types: <HealthDataType>[HealthDataType.ACTIVE_ENERGY_BURNED]);
      } catch (_) {}
      double? caloriesIn(DateTime a, DateTime b) {
        double sum = 0;
        int n = 0;
        for (final HealthDataPoint p in calPts) {
          if (!p.dateFrom.isBefore(a) && !p.dateTo.isAfter(b)) {
            final HealthValue v = p.value;
            if (v is NumericHealthValue) {
              sum += v.numericValue.toDouble();
              n++;
            }
          }
        }
        return n > 0 ? sum : null;
      }

      double? avgHrIn(DateTime a, DateTime b) {
        double sum = 0;
        int n = 0;
        for (final HealthDataPoint p in hrPts) {
          if (!p.dateFrom.isBefore(a) && !p.dateTo.isAfter(b)) {
            final HealthValue v = p.value;
            if (v is NumericHealthValue) {
              sum += v.numericValue.toDouble();
              n++;
            }
          }
        }
        return n > 0 ? sum / n : null;
      }

      for (final HealthDataPoint p in workouts) {
        final HealthValue v = p.value;
        final int dur = p.dateTo.difference(p.dateFrom).inSeconds.abs();
        if (dur < 60) {
          continue; // skip trivial blips
        }
        final String label = v is WorkoutHealthValue
            ? _prettyWorkout(v.workoutActivityType)
            : 'Workout';
        final double km =
            v is WorkoutHealthValue ? (v.totalDistance ?? 0) / 1000.0 : 0;
        opts.add(_WorkoutOpt(
          from: p.dateFrom,
          label: label,
          durationSec: dur,
          distanceKm: km,
          avgHr: avgHrIn(p.dateFrom, p.dateTo),
          calories: caloriesIn(p.dateFrom, p.dateTo),
        ));
      }
      // FALLBACK: the workout-session read is a known dead spot for Google
      // Health data, but the raw distance stream reads fine. Rebuild activity
      // windows from it — split on gaps > 10 min — and pull pace + HR.
      if (opts.isEmpty && distPts.isNotEmpty) {
        distPts.sort((HealthDataPoint a, HealthDataPoint b) =>
            a.dateFrom.compareTo(b.dateFrom));
        final List<List<HealthDataPoint>> groups = <List<HealthDataPoint>>[];
        for (final HealthDataPoint p in distPts) {
          if (groups.isEmpty ||
              p.dateFrom.difference(groups.last.last.dateTo).inMinutes.abs() >
                  10) {
            groups.add(<HealthDataPoint>[p]);
          } else {
            groups.last.add(p);
          }
        }
        for (final List<HealthDataPoint> g in groups) {
          final DateTime from = g.first.dateFrom;
          final DateTime to = g.last.dateTo;
          final int durSec = to.difference(from).inSeconds.abs();
          if (durSec < 300) {
            continue; // ignore windows under 5 min
          }
          double meters = 0;
          for (final HealthDataPoint p in g) {
            final HealthValue v = p.value;
            if (v is NumericHealthValue) {
              meters += v.numericValue.toDouble();
            }
          }
          if (meters < 200) {
            continue; // ignore near-stationary windows
          }
          opts.add(_WorkoutOpt(
            from: from,
            label: 'Activity',
            durationSec: durSec,
            distanceKm: meters / 1000.0,
            avgHr: avgHrIn(from, to),
            calories: caloriesIn(from, to),
          ));
        }
      }
      opts.sort((_WorkoutOpt a, _WorkoutOpt b) => b.from.compareTo(a.from));
    } catch (e) {
      exception = e.toString();
    }
    if (!mounted) {
      return;
    }
    Navigator.pop(context); // dismiss loader
    if (opts.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: kSurface2,
          title: const Text('Run import — diagnostics',
              style: TextStyle(color: Color(0xFFEEEEEE), fontSize: 16)),
          content: SelectableText(
            'Permission granted: ${granted ? "yes" : "no"}\n'
            'Last 7 days, records Health Connect returned:\n'
            '  • Workouts: $rawWorkouts\n'
            '  • Heart rate: $hrCount\n'
            '  • Steps: $stepCount\n'
            '  • Distance: $distCount\n'
            '${exception != null ? "Error: $exception\n" : ""}'
            '\nScreenshot this. If heart-rate/steps/distance are >0 but '
            'workouts is 0, I can rebuild your run from those signals.',
            style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 13),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    final _WorkoutOpt? chosen = await showModalBottomSheet<_WorkoutOpt>(
      context: context,
      backgroundColor: kSurface2,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _WorkoutPickerSheet(accent: widget.accent, options: opts),
    );
    if (chosen == null || !mounted) {
      return;
    }
    final Effort? eff = await _askEffort();
    if (!mounted) {
      return;
    }
    _recordRun(
      RunRecord(
        id: _newRunId(),
        date: formatDate(chosen.from),
        level: _today.level,
        distanceKm: chosen.distanceKm,
        durationSec: chosen.durationSec,
        avgHr: chosen.avgHr,
        calories: chosen.calories,
        source: 'healthconnect',
        completed: true,
        effort: (eff ?? Effort.ok).name,
      ),
      advance: true,
    );
  }

  Future<Effort?> _askEffort() {
    return showDialog<Effort>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kSurface2,
        title: const Text('How did that run feel?',
            style: TextStyle(color: Color(0xFFEEEEEE), fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          for (final Effort e in Effort.values)
            ListTile(
              title: Text(
                  e == Effort.easy
                      ? 'Easy — could have kept going'
                      : e == Effort.ok
                          ? 'About right'
                          : 'Hard — a real struggle',
                  style: const TextStyle(color: Color(0xFFDDDDDD))),
              onTap: () => Navigator.pop<Effort>(context, e),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.trainer.calibrated) {
      return _calibratePrompt();
    }
    final Workout w = _today;
    final int week = runsThisWeek(widget.runs, DateTime.now());
    final String? fuel = fuelingFlag(week, widget.cal.deficit.toDouble());
    final List<RunRecord> history = widget.runs.reversed.toList();
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Row(children: <Widget>[
            Text('5K TRAINER',
                style: TextStyle(
                    color: widget.accent,
                    fontSize: 13,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            Text('Level ${w.level} of $kMaxLevel',
                style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          ]),
          const SizedBox(height: 14),
          _todayCard(w),
          if (trainerSleepNote(_lastNightHours, _baselineHours) != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0xFF14181F),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF243246))),
              child: Row(children: <Widget>[
                const Icon(Icons.bedtime_rounded,
                    color: Color(0xFF7FA8E8), size: 20),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(
                        trainerSleepNote(_lastNightHours, _baselineHours)!,
                        style: const TextStyle(
                            color: Color(0xFFB8CBEA),
                            fontSize: 12,
                            height: 1.4))),
              ]),
            ),
          ],
          if (Advisor.configured) ...<Widget>[
            const SizedBox(height: 12),
            _coachCard(),
          ],
          if (fuel != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0xFF24210F),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF4A431A))),
              child: Row(children: <Widget>[
                const Icon(Icons.local_fire_department_rounded,
                    color: Color(0xFFCBB047), size: 20),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(fuel,
                        style: const TextStyle(
                            color: Color(0xFFD9CB8A),
                            fontSize: 12,
                            height: 1.4))),
              ]),
            ),
          ],
          const SizedBox(height: 22),
          Text('HISTORY',
              style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('No runs yet. Your first one shows up here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[700])),
            )
          else
            ...history.map(_historyTile),
        ],
      ),
    );
  }

  Widget _coachCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF262626))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Icon(Icons.psychology_rounded, color: widget.accent, size: 18),
          const SizedBox(width: 8),
          Text('RUNNING COACH',
              style: TextStyle(
                  color: widget.accent,
                  fontSize: 12,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700)),
        ]),
        if (_coachText != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(_coachText!,
              style: const TextStyle(
                  color: Color(0xFFDDDDDD), fontSize: 14, height: 1.5)),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _coaching ? null : _askCoach,
            icon: _coaching
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: widget.accent))
                : const Icon(Icons.auto_awesome_rounded, size: 18),
            label: Text(_coachText == null
                ? 'Ask your coach'
                : 'Refresh coaching'),
            style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFCCCCCC),
                side: const BorderSide(color: Color(0xFF333333)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
          ),
        ),
      ]),
    );
  }

  Widget _todayCard(Workout w) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF262626))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text("Today's workout",
            style: TextStyle(color: Colors.grey[500], fontSize: 12)),
        const SizedBox(height: 6),
        Text(w.name,
            style: const TextStyle(
                color: Color(0xFFEEEEEE),
                fontSize: 20,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            '5-min warmup · ${_fmtMin(w.runSeconds)} running '
            'over ${w.runReps} ${w.runReps == 1 ? 'block' : 'blocks'} · '
            '5-min cooldown  ·  ~${_fmtMin(w.totalSeconds)} total',
            style: TextStyle(color: Colors.grey[500], fontSize: 12, height: 1.4)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _startCoach,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Start coached run'),
            style: ElevatedButton.styleFrom(
                backgroundColor: widget.accent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: <Widget>[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _importHealthConnect,
              icon: const Icon(Icons.watch_rounded, size: 18),
              label: const Text('Import run'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFCCCCCC),
                  side: const BorderSide(color: Color(0xFF333333)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _logManual,
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('Log manually'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFCCCCCC),
                  side: const BorderSide(color: Color(0xFF333333)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _historyTile(RunRecord r) {
    final String dist =
        r.distanceKm > 0 ? '${_kmToMi(r.distanceKm).toStringAsFixed(2)} mi' : '';
    final String dur = _fmtMin(r.durationSec);
    final String pace = r.distanceKm > 0
        ? '${_paceMinPerMile(r)} /mi'
        : (r.level > 0 ? 'Level ${r.level}' : '');
    final List<String> bits = <String>[
      if (dist.isNotEmpty) dist,
      dur,
      if (pace.isNotEmpty) pace,
      if (r.avgHr != null) '${r.avgHr!.round()} bpm',
      if (r.calories != null) '${r.calories!.round()} cal',
      if (!r.completed) 'partial',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: <Widget>[
        Icon(
            r.source == 'healthconnect'
                ? Icons.watch_rounded
                : Icons.directions_run_rounded,
            size: 18,
            color: widget.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(r.date,
                style: const TextStyle(
                    color: Color(0xFFDDDDDD),
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            Text(bits.join('  ·  '),
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  String _paceMinPerMile(RunRecord r) {
    final double mi = _kmToMi(r.distanceKm);
    if (mi <= 0) {
      return '—';
    }
    final int s = (r.durationSec / mi).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _calibratePrompt() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.directions_run_rounded,
                  color: widget.accent, size: 44),
              const SizedBox(height: 16),
              const Text('Couch to 5K — tailored to you',
                  style: TextStyle(
                      color: Color(0xFFEEEEEE),
                      fontSize: 22,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(
                  'A run/walk plan that climbs to a 30-minute run, and adapts '
                  'to how each run actually goes. First, a quick question to '
                  'pick your starting point.',
                  style: TextStyle(
                      color: Colors.grey[500], fontSize: 14, height: 1.5)),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _calibrate,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: widget.accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  child: const Text('Set my starting point'),
                ),
              ),
            ]),
      ),
    );
  }
}

// ── Calibration sheet: one question → starting level ──────────────────
class _CalibrationSheet extends StatefulWidget {
  final Color accent;
  const _CalibrationSheet({required this.accent});
  @override
  State<_CalibrationSheet> createState() => _CalibrationSheetState();
}

class _CalibrationSheetState extends State<_CalibrationSheet> {
  double _minutes = 1;
  @override
  Widget build(BuildContext context) {
    final int lvl = startingLevel(_minutes);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Where are you now?',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: widget.accent)),
            const SizedBox(height: 8),
            const Text(
                'Roughly how many minutes can you run without stopping today?',
                style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 14)),
            const SizedBox(height: 18),
            Text(
                _minutes < 1
                    ? "Can't run yet"
                    : '${_minutes.round()} min continuous',
                style: TextStyle(
                    color: widget.accent,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            Slider(
              value: _minutes,
              min: 0,
              max: 35,
              divisions: 35,
              activeColor: widget.accent,
              label: '${_minutes.round()} min',
              onChanged: (double v) => setState(() => _minutes = v),
            ),
            const SizedBox(height: 4),
            Text("We'll start you at: ${workoutForLevel(lvl).name}",
                style: TextStyle(color: Colors.grey[500], fontSize: 13)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.pop<double>(context, _minutes),
                style: ElevatedButton.styleFrom(
                    backgroundColor: widget.accent,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                child: const Text('Start training'),
              ),
            ),
          ]),
    );
  }
}

// ── Manual run entry: distance (mi) + time + effort ───────────────────
class _ManualRunSheet extends StatefulWidget {
  final Color accent;
  final int level;
  const _ManualRunSheet({required this.accent, required this.level});
  @override
  State<_ManualRunSheet> createState() => _ManualRunSheetState();
}

class _ManualRunSheetState extends State<_ManualRunSheet> {
  final TextEditingController _miles = TextEditingController();
  final TextEditingController _min = TextEditingController();
  Effort _effort = Effort.ok;
  bool _countToPlan = true;

  @override
  void dispose() {
    _miles.dispose();
    _min.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double mins = double.tryParse(_min.text) ?? 0;
    final bool ok = mins > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Log a run',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: widget.accent)),
              const SizedBox(height: 16),
              Row(children: <Widget>[
                Expanded(child: _numField('DISTANCE (mi) — optional', _miles)),
                const SizedBox(width: 12),
                Expanded(child: _numField('TIME (min)', _min)),
              ]),
              const SizedBox(height: 16),
              Text('HOW DID IT FEEL?',
                  style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 11,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                  children: Effort.values.map((Effort e) {
                final bool sel = e == _effort;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _effort = e),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: sel
                                ? widget.accent
                                : const Color(0xFF111111),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: sel
                                    ? widget.accent
                                    : const Color(0xFF333333))),
                        child: Text(
                            e == Effort.easy
                                ? 'Easy'
                                : e == Effort.ok
                                    ? 'OK'
                                    : 'Hard',
                            style: TextStyle(
                                color: sel
                                    ? Colors.black
                                    : const Color(0xFFCCCCCC),
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                );
              }).toList()),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: widget.accent,
                value: _countToPlan,
                onChanged: (bool? v) =>
                    setState(() => _countToPlan = v ?? true),
                title: Text("Count as today's Level ${widget.level} workout",
                    style: const TextStyle(
                        color: Color(0xFFCCCCCC), fontSize: 13)),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: ok
                      ? () {
                          final double mi =
                              double.tryParse(_miles.text) ?? 0;
                          Navigator.pop<RunRecord>(
                              context,
                              RunRecord(
                                id: _newRunId(),
                                date: formatDate(DateTime.now()),
                                level: _countToPlan ? widget.level : 0,
                                distanceKm: mi / 0.621371,
                                durationSec: (mins * 60).round(),
                                source: 'manual',
                                completed: true,
                                effort: _effort.name,
                              ));
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: widget.accent,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: const Color(0xFF333333),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  child: const Text('Save run'),
                ),
              ),
            ]),
      ),
    );
  }

  Widget _numField(String label, TextEditingController c) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(label,
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              letterSpacing: 1,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 16, color: Color(0xFFEEEEEE)),
          decoration: _foodDec(widget.accent),
          onChanged: (_) => setState(() {})),
    ]);
  }
}

// ── In-run coach: counts down each interval, cues run/walk ────────────
class _CoachScreen extends StatefulWidget {
  final Workout workout;
  final Color accent;
  final bool audioCues;
  const _CoachScreen(
      {required this.workout, required this.accent, required this.audioCues});
  @override
  State<_CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends State<_CoachScreen> {
  Timer? _timer;
  FlutterTts? _tts;
  int _idx = 0; // current interval
  int _left = 0; // seconds left in current interval
  int _elapsed = 0; // total elapsed seconds
  bool _paused = false;
  bool _done = false;

  List<RunInterval> get _ivs => widget.workout.intervals;

  @override
  void initState() {
    super.initState();
    if (widget.audioCues) {
      _tts = FlutterTts();
    }
    _left = _ivs.isNotEmpty ? _ivs.first.seconds : 0;
    _cue(_ivs.first.kind);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tts?.stop();
    super.dispose();
  }

  void _tick() {
    if (_paused || _done) {
      return;
    }
    setState(() {
      _left--;
      _elapsed++;
    });
    if (_left <= 0) {
      _advanceInterval();
    }
  }

  void _advanceInterval() {
    if (_idx >= _ivs.length - 1) {
      _finish();
      return;
    }
    setState(() {
      _idx++;
      _left = _ivs[_idx].seconds;
    });
    _cue(_ivs[_idx].kind);
  }

  String _kindLabel(IntervalKind k) {
    switch (k) {
      case IntervalKind.warmup:
        return 'WARM UP';
      case IntervalKind.run:
        return 'RUN';
      case IntervalKind.walk:
        return 'WALK';
      case IntervalKind.cooldown:
        return 'COOL DOWN';
    }
  }

  Future<void> _cue(IntervalKind k) async {
    try {
      final bool has = (await Vibration.hasVibrator());
      if (has) {
        if (k == IntervalKind.run) {
          Vibration.vibrate(duration: 600);
        } else {
          Vibration.vibrate(pattern: <int>[0, 200, 150, 200]);
        }
      }
    } catch (_) {}
    if (widget.audioCues && _tts != null) {
      final String phrase = k == IntervalKind.run
          ? 'Run'
          : k == IntervalKind.walk
              ? 'Walk'
              : k == IntervalKind.warmup
                  ? 'Warm up'
                  : 'Cool down';
      try {
        await _tts!.speak(phrase);
      } catch (_) {}
    }
  }

  void _finish() {
    setState(() => _done = true);
    _timer?.cancel();
  }

  String _mmss(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  Color _kindColor(IntervalKind k) {
    if (k == IntervalKind.run) {
      return widget.accent;
    }
    if (k == IntervalKind.walk) {
      return const Color(0xFF5B8DEF);
    }
    return const Color(0xFF888888);
  }

  @override
  Widget build(BuildContext context) {
    if (_done) {
      return _finishView();
    }
    final RunInterval cur = _ivs[_idx];
    final Color c = _kindColor(cur.kind);
    final RunInterval? next =
        _idx < _ivs.length - 1 ? _ivs[_idx + 1] : null;
    return Scaffold(
      backgroundColor: kBgDeep,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: <Widget>[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop<RunOutcome>(context, null),
                child: Text('Stop',
                    style: TextStyle(color: Colors.grey[500])),
              ),
            ),
            Text('Level ${widget.workout.level}  ·  '
                'interval ${_idx + 1} of ${_ivs.length}',
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const Spacer(),
            Text(_kindLabel(cur.kind),
                style: TextStyle(
                    color: c,
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3)),
            const SizedBox(height: 12),
            Text(_mmss(_left),
                style: const TextStyle(
                    color: Color(0xFFEEEEEE),
                    fontSize: 78,
                    fontWeight: FontWeight.w200,
                    fontFeatures: <FontFeature>[
                      FontFeature.tabularFigures()
                    ])),
            const SizedBox(height: 8),
            if (next != null)
              Text('Next: ${_kindLabel(next.kind)} · ${_mmss(next.seconds)}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 14)),
            const Spacer(),
            Text('Elapsed ${_mmss(_elapsed)} / ${_mmss(widget.workout.totalSeconds)}',
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: () => setState(() => _paused = !_paused),
                icon: Icon(
                    _paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                label: Text(_paused ? 'Resume' : 'Pause'),
                style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _paused ? widget.accent : const Color(0xFF1E1E1E),
                    foregroundColor:
                        _paused ? Colors.black : const Color(0xFFEEEEEE),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    textStyle: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _finishView() {
    return Scaffold(
      backgroundColor: kBgDeep,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(Icons.check_circle_rounded,
                    color: widget.accent, size: 56),
                const SizedBox(height: 16),
                const Text('Run complete',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Color(0xFFEEEEEE),
                        fontSize: 24,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text('How did that feel? It tunes your next workout.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[500], fontSize: 14)),
                const SizedBox(height: 24),
                for (final Effort e in Effort.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop<RunOutcome>(context,
                            RunOutcome(completed: true, effort: e)),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFEEEEEE),
                            side: BorderSide(color: widget.accent),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        child: Text(
                            e == Effort.easy
                                ? 'Easy — could have kept going'
                                : e == Effort.ok
                                    ? 'About right'
                                    : 'Hard — a real struggle',
                            style: const TextStyle(fontSize: 15)),
                      ),
                    ),
                  ),
              ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SLEEP UI — imported from Health Connect (Pixel Watch), never manual.
//
// When there's data: last night + stages, a transparent readiness read, the
// 7-day average, and history. When there's none: a quiet prompt. Sleep is
// purely additive — nothing here feeds the raw weight/TDEE numbers.
// ═══════════════════════════════════════════════════════════════════════

class SleepScreen extends StatefulWidget {
  final Color accent;
  final UserCalibration cal;
  final List<DailyLog> logs;
  final List<RunRecord> runs;
  final List<SleepEntry> sleep;
  final void Function(List<SleepEntry>) onSetSleep;
  const SleepScreen(
      {super.key,
      required this.accent,
      required this.cal,
      required this.logs,
      required this.runs,
      required this.sleep,
      required this.onSetSleep});
  @override
  State<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends State<SleepScreen> {
  bool _importing = false;

  SleepEntry? get _last => SleepMath.latest(widget.sleep);
  double? get _baseline => SleepMath.baselineHours(widget.sleep, DateTime.now());

  String _hm(int minutes) => '${minutes ~/ 60}h ${minutes % 60}m';

  void _merge(List<SleepEntry> imported) {
    final Map<String, SleepEntry> byDate = <String, SleepEntry>{
      for (final SleepEntry e in widget.sleep) e.date: e
    };
    for (final SleepEntry e in imported) {
      byDate[e.date] = e;
    }
    final List<SleepEntry> list = byDate.values.toList()
      ..sort((SleepEntry a, SleepEntry b) => b.date.compareTo(a.date));
    widget.onSetSleep(list);
  }

  Future<void> _importSleep() async {
    setState(() => _importing = true);
    final List<SleepEntry> found = <SleepEntry>[];
    String? error;
    try {
      final Health health = Health();
      await health.configure();
      final List<HealthDataType> types = <HealthDataType>[
        HealthDataType.SLEEP_SESSION,
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_AWAKE,
        HealthDataType.HEART_RATE,
        HealthDataType.RESTING_HEART_RATE,
        HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
        HealthDataType.RESPIRATORY_RATE,
      ];
      final bool granted = await health.requestAuthorization(types,
          permissions:
              types.map((_) => HealthDataAccess.READ).toList());
      if (!granted) {
        error = 'Health Connect sleep permission was denied.';
      } else {
        final DateTime now = DateTime.now();
        final DateTime start = now.subtract(const Duration(days: 7));
        final List<HealthDataPoint> all = await health.getHealthDataFromTypes(
            startTime: start, endTime: now, types: types);
        final List<HealthDataPoint> sessions = all
            .where((HealthDataPoint p) =>
                p.type == HealthDataType.SLEEP_SESSION)
            .toList();
        for (final HealthDataPoint s in sessions) {
          int stageMinutes(HealthDataType t) {
            int m = 0;
            for (final HealthDataPoint p in all) {
              if (p.type == t &&
                  !p.dateFrom.isBefore(s.dateFrom) &&
                  !p.dateTo.isAfter(s.dateTo)) {
                m += p.dateTo.difference(p.dateFrom).inMinutes;
              }
            }
            return m;
          }

          final int deep = stageMinutes(HealthDataType.SLEEP_DEEP);
          final int rem = stageMinutes(HealthDataType.SLEEP_REM);
          final int light = stageMinutes(HealthDataType.SLEEP_LIGHT);
          final int awake = stageMinutes(HealthDataType.SLEEP_AWAKE);
          final int sessionMin =
              s.dateTo.difference(s.dateFrom).inMinutes.abs();
          final int asleep =
              (deep + rem + light) > 0 ? (deep + rem + light) : sessionMin;
          // Average heart rate during the session window.
          double hrSum = 0;
          int hrN = 0;
          for (final HealthDataPoint p in all) {
            if (p.type == HealthDataType.HEART_RATE &&
                !p.dateFrom.isBefore(s.dateFrom) &&
                !p.dateTo.isAfter(s.dateTo)) {
              final HealthValue v = p.value;
              if (v is NumericHealthValue) {
                hrSum += v.numericValue.toDouble();
                hrN++;
              }
            }
          }
          // Overnight recovery vitals — averaged over the night (± a couple
          // hours, since watches often finalise these near wake time).
          double? avgVital(HealthDataType t) {
            final DateTime a = s.dateFrom.subtract(const Duration(hours: 1));
            final DateTime b = s.dateTo.add(const Duration(hours: 3));
            double sum = 0;
            int n = 0;
            for (final HealthDataPoint p in all) {
              if (p.type == t &&
                  !p.dateFrom.isBefore(a) &&
                  !p.dateTo.isAfter(b)) {
                final HealthValue v = p.value;
                if (v is NumericHealthValue) {
                  sum += v.numericValue.toDouble();
                  n++;
                }
              }
            }
            return n > 0 ? sum / n : null;
          }

          String hhmm(DateTime d) =>
              '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
          found.add(SleepEntry(
            id: 'sl_${s.dateFrom.millisecondsSinceEpoch}',
            date: formatDate(s.dateTo),
            asleepMinutes: asleep,
            deepMin: deep > 0 ? deep : null,
            remMin: rem > 0 ? rem : null,
            lightMin: light > 0 ? light : null,
            awakeMin: awake > 0 ? awake : null,
            avgHr: hrN > 0 ? hrSum / hrN : null,
            restingHr: avgVital(HealthDataType.RESTING_HEART_RATE),
            hrv: avgVital(HealthDataType.HEART_RATE_VARIABILITY_RMSSD),
            respiratoryRate: avgVital(HealthDataType.RESPIRATORY_RATE),
            bedTime: hhmm(s.dateFrom),
            wakeTime: hhmm(s.dateTo),
          ));
        }
        if (found.isEmpty) {
          error = 'No sleep found in Health Connect (last 7 days). '
              'Did you wear the watch overnight?';
        }
      }
    } catch (e) {
      error = 'Health Connect unavailable on this device.';
    }
    if (!mounted) {
      return;
    }
    setState(() => _importing = false);
    if (found.isNotEmpty) {
      _merge(found);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFF2A2A2A),
          content: Text('Imported ${found.length} '
              'night${found.length == 1 ? '' : 's'} of sleep.')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFF2A2A2A),
          content: Text(error ?? 'Nothing to import.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sleep.isEmpty) {
      return _emptyState();
    }
    final SleepEntry last = _last!;
    final double? avg7 =
        SleepMath.averageHours(widget.sleep, DateTime.now(), 7);
    final Readiness? readiness = computeReadiness(
      lastNightHours: last.hours,
      baselineHours: _baseline,
      runsLast7: runsThisWeek(widget.runs, DateTime.now()),
      deficit: widget.cal.deficit,
      restingHr: last.restingHr,
      baselineRestingHr:
          SleepMath.baselineRestingHr(widget.sleep, DateTime.now()),
      hrv: last.hrv,
      baselineHrv: SleepMath.baselineHrv(widget.sleep, DateTime.now()),
    );
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Row(children: <Widget>[
            Text('SLEEP',
                style: TextStyle(
                    color: widget.accent,
                    fontSize: 13,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            if (avg7 != null)
              Text('7-day avg ${avg7.toStringAsFixed(1)}h',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          ]),
          const SizedBox(height: 14),
          _lastNightCard(last),
          if (readiness != null) ...<Widget>[
            const SizedBox(height: 12),
            _readinessCard(readiness),
          ],
          const SizedBox(height: 12),
          _importButton(),
          const SizedBox(height: 22),
          Text('HISTORY',
              style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...widget.sleep.map(_historyTile),
        ],
      ),
    );
  }

  Widget _lastNightCard(SleepEntry e) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF262626))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('Last night · ${e.date}',
            style: TextStyle(color: Colors.grey[500], fontSize: 12)),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
          Text(e.hours.toStringAsFixed(1),
              style: const TextStyle(
                  color: Color(0xFFEEEEEE),
                  fontSize: 40,
                  fontWeight: FontWeight.w800)),
          const SizedBox(width: 4),
          const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('hours asleep',
                  style: TextStyle(color: Color(0xFF888888), fontSize: 13))),
          const Spacer(),
          if (e.bedTime.isNotEmpty)
            Text('${e.bedTime} → ${e.wakeTime}',
                style: TextStyle(color: Colors.grey[500], fontSize: 13)),
        ]),
        if (e.hasStages) ...<Widget>[
          const SizedBox(height: 14),
          _stagesBar(e),
          const SizedBox(height: 8),
          Wrap(spacing: 14, runSpacing: 4, children: <Widget>[
            _stageKey('Deep', e.deepMin ?? 0, const Color(0xFF3D5AFE)),
            _stageKey('REM', e.remMin ?? 0, const Color(0xFF7C4DFF)),
            _stageKey('Light', e.lightMin ?? 0, const Color(0xFF5B8DEF)),
            if ((e.awakeMin ?? 0) > 0)
              _stageKey('Awake', e.awakeMin ?? 0, const Color(0xFF555555)),
          ]),
        ],
        if (e.avgHr != null) ...<Widget>[
          const SizedBox(height: 10),
          Row(children: <Widget>[
            const Icon(Icons.favorite_rounded,
                color: Color(0xFFCC5555), size: 15),
            const SizedBox(width: 6),
            Text('${e.avgHr!.round()} bpm overnight',
                style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          ]),
        ],
        if (e.restingHr != null || e.hrv != null || e.respiratoryRate != null)
          ...<Widget>[
            const SizedBox(height: 8),
            Wrap(spacing: 14, runSpacing: 4, children: <Widget>[
              if (e.restingHr != null)
                _vital('Resting HR', '${e.restingHr!.round()} bpm'),
              if (e.hrv != null) _vital('HRV', '${e.hrv!.round()} ms'),
              if (e.respiratoryRate != null)
                _vital('Resp', '${e.respiratoryRate!.toStringAsFixed(1)}/min'),
            ]),
          ],
      ]),
    );
  }

  Widget _vital(String label, String value) {
    return Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
      Text('$label ',
          style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      Text(value,
          style: const TextStyle(
              color: Color(0xFFCCCCCC),
              fontSize: 12,
              fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _stagesBar(SleepEntry e) {
    final int deep = e.deepMin ?? 0;
    final int rem = e.remMin ?? 0;
    final int light = e.lightMin ?? 0;
    final int awake = e.awakeMin ?? 0;
    final int total = deep + rem + light + awake;
    if (total == 0) {
      return const SizedBox.shrink();
    }
    Widget seg(int m, Color c) =>
        m == 0 ? const SizedBox.shrink() : Expanded(flex: m, child: Container(color: c));
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 14,
        child: Row(children: <Widget>[
          seg(deep, const Color(0xFF3D5AFE)),
          seg(rem, const Color(0xFF7C4DFF)),
          seg(light, const Color(0xFF5B8DEF)),
          seg(awake, const Color(0xFF555555)),
        ]),
      ),
    );
  }

  Widget _stageKey(String label, int minutes, Color c) {
    return Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
      Container(width: 9, height: 9,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text('$label ${_hm(minutes)}',
          style: TextStyle(color: Colors.grey[500], fontSize: 11)),
    ]);
  }

  Widget _readinessCard(Readiness r) {
    final Color c = r.score >= 75
        ? const Color(0xFF4CAF7D)
        : (r.score >= 50 ? const Color(0xFFCBB047) : const Color(0xFFCC6B5A));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF262626))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Text('READINESS',
              style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('${r.score}',
              style: TextStyle(
                  color: c, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Text(r.label,
              style: TextStyle(
                  color: c, fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        ...r.factors.map((String f) => Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                Text('· ',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                Expanded(
                    child: Text(f,
                        style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 12,
                            height: 1.4))),
              ]),
            )),
      ]),
    );
  }

  Widget _importButton() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: _importing ? null : _importSleep,
        icon: _importing
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: widget.accent))
            : const Icon(Icons.sync_rounded, size: 18),
        label: const Text('Import sleep from Health Connect'),
        style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFCCCCCC),
            side: const BorderSide(color: Color(0xFF333333)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
    );
  }

  Widget _historyTile(SleepEntry e) {
    final List<String> bits = <String>[
      '${e.hours.toStringAsFixed(1)}h',
      if (e.hasStages) 'deep ${_hm(e.deepMin ?? 0)}',
      if (e.avgHr != null) '${e.avgHr!.round()} bpm',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: <Widget>[
        Icon(Icons.bedtime_rounded, size: 18, color: widget.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(e.date,
                style: const TextStyle(
                    color: Color(0xFFDDDDDD),
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            Text(bits.join('  ·  '),
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  Widget _emptyState() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.bedtime_rounded, color: widget.accent, size: 44),
              const SizedBox(height: 16),
              const Text('Sleep',
                  style: TextStyle(
                      color: Color(0xFFEEEEEE),
                      fontSize: 24,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(
                  'Wear your Pixel Watch to bed and your sleep imports here — '
                  'duration, stages, and overnight heart rate. It feeds your '
                  'readiness, the coach, and explains odd scale jumps.\n\n'
                  'No watch on a given night? That night just stays blank — '
                  'nothing else in the app is affected.',
                  style: TextStyle(
                      color: Colors.grey[500], fontSize: 14, height: 1.5)),
              const SizedBox(height: 24),
              _importButton(),
            ]),
      ),
    );
  }
}

// ── Edit a logged food: scale by grams/servings, all macros auto-recompute ──
class _EditEntrySheet extends StatefulWidget {
  final Color accent;
  final FoodEntry entry;
  final void Function(FoodEntry) onSave;
  final VoidCallback onDelete;
  const _EditEntrySheet(
      {required this.accent,
      required this.entry,
      required this.onSave,
      required this.onDelete});
  @override
  State<_EditEntrySheet> createState() => _EditEntrySheetState();
}

class _EditEntrySheetState extends State<_EditEntrySheet> {
  late final TextEditingController _name, _amount, _cal, _p, _f, _c, _fiber, _sodium;
  late final bool _gramsMode;
  late final double _baseCal, _baseP, _baseF, _baseC, _baseFiber, _baseSodium, _baseGrams;

  @override
  void initState() {
    super.initState();
    final FoodEntry e = widget.entry;
    _gramsMode = e.baseGrams != null && e.baseGrams! > 0;
    _baseGrams = e.baseGrams ?? 0;
    _baseCal = e.calories;
    _baseP = e.protein;
    _baseF = e.fat;
    _baseC = e.carbs;
    _baseFiber = e.nutrients['fiber'] ?? 0;
    _baseSodium = e.nutrients['sodium'] ?? 0;
    _name = TextEditingController(text: e.name);
    _amount = TextEditingController(
        text: _gramsMode ? _trim(_baseGrams, dp: 1) : '1');
    _cal = TextEditingController(text: _trim(_baseCal));
    _p = TextEditingController(text: _trim(_baseP));
    _f = TextEditingController(text: _trim(_baseF));
    _c = TextEditingController(text: _trim(_baseC));
    _fiber = TextEditingController(
        text: _baseFiber > 0 ? _trim(_baseFiber, dp: 1) : '');
    _sodium = TextEditingController(
        text: _baseSodium > 0 ? _trim(_baseSodium, dp: 1) : '');
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name, _amount, _cal, _p, _f, _c, _fiber, _sodium
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _factor {
    final double v = double.tryParse(_amount.text) ?? 0;
    if (v <= 0) {
      return 0;
    }
    return _gramsMode ? (_baseGrams > 0 ? v / _baseGrams : 0) : v;
  }

  // Changing the amount refills every macro field from the original values.
  void _rescale() {
    final double f = _factor;
    _cal.text = _trim(_baseCal * f);
    _p.text = _trim(_baseP * f);
    _f.text = _trim(_baseF * f);
    _c.text = _trim(_baseC * f);
    _fiber.text = _baseFiber > 0 ? _trim(_baseFiber * f, dp: 1) : '';
    _sodium.text = _baseSodium > 0 ? _trim(_baseSodium * f, dp: 1) : '';
    setState(() {});
  }

  String get _servingLabel {
    if (_gramsMode) {
      final double g = double.tryParse(_amount.text) ?? _baseGrams;
      return '${_trim(g, dp: 1)} g';
    }
    final double a = double.tryParse(_amount.text) ?? 1;
    if (a == 1) {
      return widget.entry.serving;
    }
    return '${_trim(a, dp: 2)}× ${widget.entry.serving}';
  }

  void _save() {
    final double f = _factor;
    // Scale every stored micronutrient, then let the visible fields win.
    final Map<String, double> micros = widget.entry.nutrients
        .map((String k, double v) => MapEntry<String, double>(k, v * f));
    final double? fiber = double.tryParse(_fiber.text);
    final double? sodium = double.tryParse(_sodium.text);
    if (fiber != null && fiber > 0) {
      micros['fiber'] = fiber;
    } else {
      micros.remove('fiber');
    }
    if (sodium != null && sodium > 0) {
      micros['sodium'] = sodium;
    } else {
      micros.remove('sodium');
    }
    widget.onSave(FoodEntry(
      id: widget.entry.id,
      date: widget.entry.date,
      time: widget.entry.time,
      name: _name.text.trim().isEmpty ? widget.entry.name : _name.text.trim(),
      serving: _servingLabel,
      calories: double.tryParse(_cal.text) ?? _baseCal * f,
      protein: double.tryParse(_p.text) ?? _baseP * f,
      fat: double.tryParse(_f.text) ?? _baseF * f,
      carbs: double.tryParse(_c.text) ?? _baseC * f,
      nutrients: micros,
      source: widget.entry.source,
      barcode: widget.entry.barcode,
      baseGrams:
          _gramsMode ? (double.tryParse(_amount.text) ?? _baseGrams) : widget.entry.baseGrams,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bool ok = (double.tryParse(_cal.text) ?? -1) >= 0 &&
        (double.tryParse(_amount.text) ?? 0) > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              24),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Edit food',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: widget.accent)),
              const SizedBox(height: 16),
              _field('NAME', _name, text: true),
              const SizedBox(height: 12),
              _field(
                  _gramsMode ? 'AMOUNT (grams)' : 'AMOUNT (× servings)',
                  _amount,
                  onChanged: (_) => _rescale()),
              const SizedBox(height: 6),
              Text(
                  _gramsMode
                      ? 'Change the grams — calories and macros re-scale automatically.'
                      : 'Change the multiplier — everything re-scales. (No weight stored for this item.)',
                  style: TextStyle(color: Colors.grey[600], fontSize: 11)),
              const SizedBox(height: 14),
              _field('CALORIES', _cal),
              const SizedBox(height: 12),
              Row(children: <Widget>[
                Expanded(child: _field('PROTEIN (g)', _p)),
                const SizedBox(width: 10),
                Expanded(child: _field('FAT (g)', _f)),
              ]),
              const SizedBox(height: 12),
              Row(children: <Widget>[
                Expanded(child: _field('CARBS (g)', _c)),
                const SizedBox(width: 10),
                Expanded(child: _field('FIBER (g)', _fiber)),
              ]),
              const SizedBox(height: 12),
              _field('SODIUM (mg)', _sodium),
              const SizedBox(height: 20),
              Row(children: <Widget>[
                Expanded(
                    child: SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: ok ? _save : null,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: widget.accent,
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: const Color(0xFF333333),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              textStyle: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          child: const Text('Save'),
                        ))),
                const SizedBox(width: 10),
                IconButton(
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline_rounded,
                        color: Color(0xFFCC5555))),
              ]),
            ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController c,
      {bool text = false, void Function(String)? onChanged}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(label,
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey[600],
              letterSpacing: 1,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      TextField(
          controller: c,
          keyboardType: text
              ? TextInputType.text
              : const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 16, color: Color(0xFFEEEEEE)),
          decoration: _foodDec(widget.accent),
          onChanged: onChanged ?? (_) => setState(() {})),
    ]);
  }
}

// ── Health Connect workout candidates + picker (run import) ──────────
class _WorkoutOpt {
  final DateTime from;
  final String label;
  final int durationSec;
  final double distanceKm;
  final double? avgHr;
  final double? calories;
  const _WorkoutOpt(
      {required this.from,
      required this.label,
      required this.durationSec,
      required this.distanceKm,
      this.avgHr,
      this.calories});
}

String _prettyWorkout(HealthWorkoutActivityType t) {
  final String s = t.name.replaceAll('_', ' ').toLowerCase();
  return s.isEmpty ? 'Workout' : '${s[0].toUpperCase()}${s.substring(1)}';
}

class _WorkoutPickerSheet extends StatelessWidget {
  final Color accent;
  final List<_WorkoutOpt> options;
  const _WorkoutPickerSheet({required this.accent, required this.options});
  @override
  Widget build(BuildContext context) {
    String when(DateTime d) =>
        '${formatDate(d)}  ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final int n = options.length > 20 ? 20 : options.length;
    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewPadding.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Pick a workout to log',
                  style: TextStyle(
                      color: accent,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: n,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: Color(0xFF1C1C1C)),
              itemBuilder: (_, int i) {
                final _WorkoutOpt o = options[i];
                final String mi = o.distanceKm > 0
                    ? '${(o.distanceKm * 0.621371).toStringAsFixed(2)} mi  ·  '
                    : '';
                return ListTile(
                  leading:
                      Icon(Icons.directions_run_rounded, color: accent),
                  title: Text('${o.label}  ·  ${(o.durationSec / 60).round()} min',
                      style: const TextStyle(
                          color: Color(0xFFEEEEEE),
                          fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      '$mi${when(o.from)}${o.avgHr != null ? "  ·  ${o.avgHr!.round()} bpm" : ""}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                  onTap: () => Navigator.pop<_WorkoutOpt>(context, o),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
