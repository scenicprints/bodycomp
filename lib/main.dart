import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'updater.dart';
import 'food.dart';

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
  }) {
    return UserCalibration(
      startWeight: startWeight,
      startBf: startBf,
      targetBf: targetBf ?? this.targetBf,
      activityMult: activityMult ?? this.activityMult,
      deficit: deficit ?? this.deficit,
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

  @override
  void initState() {
    super.initState();
    _cal = AppStorage.getCalibration();
    _logs = AppStorage.getLogs();
    _dismissed = AppStorage.getDismissedMilestones();
    _foods = AppStorage.getFoods();
    _fasted = AppStorage.getFastedDates();
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

  void _resetAll() {
    AppStorage.clearAll();
    setState(() {
      _cal = null;
      _logs = [];
      _dismissed = [];
      _foods = [];
      _fasted = [];
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
              onSetCal: _setCal,
              onSetLogs: _setLogs,
              onSetFoods: _setFoods,
              onSetFasted: _setFasted,
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
  final void Function(UserCalibration) onSetCal;
  final void Function(List<DailyLog>) onSetLogs;
  final void Function(List<FoodEntry>) onSetFoods;
  final void Function(List<String>) onSetFasted;
  final void Function(double) onDismiss;
  final VoidCallback onReset;
  const HomeShell(
      {super.key,
      required this.cal,
      required this.logs,
      required this.dismissed,
      required this.foods,
      required this.fasted,
      required this.onSetCal,
      required this.onSetLogs,
      required this.onSetFoods,
      required this.onSetFasted,
      required this.onDismiss,
      required this.onReset});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
          child: IndexedStack(index: _tab, children: [
        DashboardScreen(
            cal: widget.cal,
            logs: widget.logs,
            dismissed: widget.dismissed,
            foods: widget.foods,
            fasted: widget.fasted,
            onSetLogs: widget.onSetLogs,
            onDismiss: widget.onDismiss),
        FoodScreen(
            cal: widget.cal,
            logs: widget.logs,
            foods: widget.foods,
            fasted: widget.fasted,
            onSetFoods: widget.onSetFoods,
            onSetFasted: widget.onSetFasted),
        LedgerScreen(
            logs: widget.logs, cal: widget.cal, onSetLogs: widget.onSetLogs),
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
                icon: Icon(Icons.list_alt_rounded), label: 'LEDGER'),
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
  final void Function(List<DailyLog>) onSetLogs;
  final void Function(double) onDismiss;
  const DashboardScreen(
      {super.key,
      required this.cal,
      required this.logs,
      required this.dismissed,
      required this.foods,
      required this.fasted,
      required this.onSetLogs,
      required this.onDismiss});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _plateauDismissed = false;
  int _chartRange = 0;

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
          initCal: existing?.calories,
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
          UpdateCard(accent: accent),
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
  final void Function(List<FoodEntry>) onSetFoods;
  final void Function(List<String>) onSetFasted;
  const FoodScreen(
      {super.key,
      required this.cal,
      required this.logs,
      required this.foods,
      required this.fasted,
      required this.onSetFoods,
      required this.onSetFasted});
  @override
  State<FoodScreen> createState() => _FoodScreenState();
}

class _FoodScreenState extends State<FoodScreen> {
  late String _date;

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

  Future<String?> _pickDate(String initial) async {
    final DateTime? d = await showDatePicker(
        context: context,
        initialDate: DateTime.parse(initial),
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        builder: (BuildContext ctx, Widget? child) => Theme(
            data: ThemeData.dark().copyWith(
                colorScheme:
                    ColorScheme.dark(primary: _accent, surface: kSurface2)),
            child: child!));
    return d != null ? formatDate(d) : null;
  }

  void _moveEntry(FoodEntry e, String date) {
    widget.onSetFoods(widget.foods
        .map((FoodEntry x) => x.id == e.id ? x.copyWith(date: date) : x)
        .toList());
  }

  void _copyEntry(FoodEntry e, String date) {
    widget.onSetFoods(List<FoodEntry>.from(widget.foods)
      ..add(e.copyWith(id: _newId(), date: date)));
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
          _menuTile(Icons.qr_code_scanner_rounded, 'Scan barcode',
              'Look up nutrition automatically', () {
            Navigator.pop(context);
            _scanBarcode();
          }),
          _menuTile(Icons.search_rounded, 'Search by name',
              'For foods without a barcode (e.g. onion)', () {
            Navigator.pop(context);
            _searchFood();
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

  void _openConfirm(FoodTemplate t) {
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
              time: _nowTime()));
          Navigator.pop(context);
        },
      ),
    );
  }

  void _openEditor({FoodEntry? existing, String? barcode}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ManualFoodSheet(
        accent: _accent,
        existing: existing,
        onSave: (FoodEntry e) {
          if (existing != null) {
            _updateEntry(e);
          } else {
            _addEntry(e);
          }
          Navigator.pop(context);
        },
        onDelete: existing == null
            ? null
            : () {
                _deleteEntry(existing.id);
                Navigator.pop(context);
              },
        onMove: existing == null
            ? null
            : () async {
                Navigator.pop(context);
                final String? d = await _pickDate(existing.date);
                if (d != null) {
                  _moveEntry(existing, d);
                }
              },
        onCopy: existing == null
            ? null
            : () async {
                Navigator.pop(context);
                final String? d = await _pickDate(existing.date);
                if (d != null) {
                  _copyEntry(existing, d);
                }
              },
        buildEntry: (String name, String serving, double cal, double p,
            double f, double c, Map<String, double> micros) {
          return FoodEntry(
            id: existing?.id ?? _newId(),
            date: existing?.date ?? _date,
            time: existing?.time ?? _nowTime(),
            name: name,
            serving: serving,
            calories: cal,
            protein: p,
            fat: f,
            carbs: c,
            nutrients: micros,
            source: existing?.source ?? 'manual',
            barcode: existing?.barcode ?? barcode,
          );
        },
      ),
    );
  }

  List<Widget> _groupedFoods(List<FoodEntry> dayFoods, Color accent) {
    const List<String> order = <String>[
      'Breakfast',
      'Lunch',
      'Dinner',
      'Snacks',
      'Other'
    ];
    final Map<String, List<FoodEntry>> groups = <String, List<FoodEntry>>{};
    for (final FoodEntry e in dayFoods) {
      (groups[e.mealPeriod] ??= <FoodEntry>[]).add(e);
    }
    final List<Widget> out = <Widget>[];
    for (final String period in order) {
      final List<FoodEntry>? list = groups[period];
      if (list == null || list.isEmpty) {
        continue;
      }
      final double cal =
          list.fold<double>(0, (double s, FoodEntry e) => s + e.calories);
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(period.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700)),
          Text('${cal.round()} cal',
              style: TextStyle(fontSize: 11, color: Colors.grey[700])),
        ]),
      ));
      for (final FoodEntry e in list) {
        out.add(_FoodCard(
            entry: e,
            accent: accent,
            onTap: () => _openEditor(existing: e)));
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
        if (dayFoods.isEmpty) ...[
          _fastedCard(accent),
        ] else
          ..._groupedFoods(dayFoods, accent),
        if (totals.nutrients.isNotEmpty) ...[
          const SizedBox(height: 10),
          _MicroPanel(nutrients: totals.nutrients),
        ],
      ]),
      Positioned(
        bottom: 16,
        left: 16,
        right: 16,
        child: SizedBox(
          height: 56,
          child: ElevatedButton.icon(
            onPressed: _showAddMenu,
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
  const _FoodCard(
      {required this.entry, required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: kSurface0,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder)),
            child: Row(children: [
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
  late final TextEditingController _amount;
  late bool _byServing;

  bool get _hasServing => widget.template.servingGrams != null;

  @override
  void initState() {
    super.initState();
    _byServing = _hasServing;
    _amount = TextEditingController(
        text: _byServing
            ? '1'
            : _trim(widget.template.servingGrams ?? 100, dp: 1));
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double get _amountVal => double.tryParse(_amount.text) ?? 0;

  double get _grams =>
      _byServing ? _amountVal * (widget.template.servingGrams ?? 0) : _amountVal;

  String get _label {
    if (_byServing) {
      final String unit = _amountVal == 1 ? 'serving' : 'servings';
      return '${_trim(_amountVal, dp: 1)} $unit (${_trim(_grams)} g)';
    }
    return '${_trim(_grams)} g';
  }

  void _setMode(bool byServing) {
    setState(() {
      _byServing = byServing;
      _amount.text =
          byServing ? '1' : _trim(widget.template.servingGrams ?? 100, dp: 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final FoodTemplate t = widget.template;
    final double s = _grams / 100.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom +
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
            if (_hasServing) ...[
              Row(children: [
                _modeChip('Servings', _byServing, () => _setMode(true)),
                const SizedBox(width: 8),
                _modeChip('Grams', !_byServing, () => _setMode(false)),
              ]),
              const SizedBox(height: 12),
            ],
            Text(
                _byServing
                    ? 'SERVINGS (1 = ${_trim(t.servingGrams ?? 0)} g)'
                    : 'AMOUNT (GRAMS)',
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
  final void Function(FoodEntry) onSave;
  final VoidCallback? onDelete;
  final VoidCallback? onMove;
  final VoidCallback? onCopy;
  final FoodEntry Function(String name, String serving, double cal, double p,
      double f, double c, Map<String, double> micros) buildEntry;
  const _ManualFoodSheet(
      {required this.accent,
      required this.existing,
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

  @override
  void initState() {
    super.initState();
    final FoodEntry? e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _serving = TextEditingController(text: e?.serving ?? '');
    _cal = TextEditingController(text: e != null ? _trim(e.calories) : '');
    _p = TextEditingController(text: e != null ? _trim(e.protein) : '');
    _f = TextEditingController(text: e != null ? _trim(e.fat) : '');
    _c = TextEditingController(text: e != null ? _trim(e.carbs) : '');
    _fiber = TextEditingController(
        text: e != null && (e.nutrients['fiber'] ?? 0) > 0
            ? _trim(e.nutrients['fiber']!, dp: 1)
            : '');
    _sodium = TextEditingController(
        text: e != null && (e.nutrients['sodium'] ?? 0) > 0
            ? _trim(e.nutrients['sodium']!, dp: 1)
            : '');
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name, _serving, _cal, _p, _f, _c, _fiber, _sodium
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
    widget.onSave(widget.buildEntry(
      _name.text.trim(),
      _serving.text.trim().isEmpty ? '1 serving' : _serving.text.trim(),
      double.tryParse(_cal.text) ?? 0,
      double.tryParse(_p.text) ?? 0,
      double.tryParse(_f.text) ?? 0,
      double.tryParse(_c.text) ?? 0,
      micros,
    ));
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
