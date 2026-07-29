import 'dart:math';

import 'main.dart';
import 'food.dart';
import 'sleep.dart';
import 'trainer.dart';

// ═══════════════════════════════════════════════════════════════════════
// GOALS — the ladder of small wins on the way to the goal weight.
//
// Six lanes, each showing ONE live goal generated relative to where the user
// actually is right now; clear it and the lane hands over the next one. The
// ladders are generated (not a fixed hand-written list) so they can't run dry
// over a long journey, and the repeatable ones recur forever.
//
// Everything auto-verifies from data already logged (weight/BF/lean, macros,
// fasted days, runs + HR, sleep). Opt-in CHALLENGES add the manual fun ones.
//
// Design rule, same as the coach: this REWARDS, it never nags. A missed day
// earns nothing and costs nothing; one off-day never breaks a streak, and
// earned freezes cover a second.
// ═══════════════════════════════════════════════════════════════════════

enum Lane { weight, body, running, nutrition, consistency, sleep }

extension LaneInfo on Lane {
  String get label => switch (this) {
        Lane.weight => 'WEIGHT',
        Lane.body => 'BODY COMP',
        Lane.running => 'RUNNING',
        Lane.nutrition => 'NUTRITION',
        Lane.consistency => 'CONSISTENCY',
        Lane.sleep => 'SLEEP',
      };
}

/// XP awards by size of win.
const int kXpSmall = 50;
const int kXpMed = 100;
const int kXpBig = 250;
const int kXpHuge = 1000;

class Goal {
  final String id;
  final Lane lane;
  final String title;
  final String desc;
  final String emoji;
  final int xp;
  final double progress; // 0..1
  final bool done;
  final int timesDone; // repeatables show a ×N tally
  final bool repeatable;

  const Goal({
    required this.id,
    required this.lane,
    required this.title,
    required this.desc,
    required this.emoji,
    required this.xp,
    required this.progress,
    required this.done,
    this.timesDone = 0,
    this.repeatable = false,
  });
}

// ── levels ──────────────────────────────────────────────────────────────

/// Cumulative XP to REACH [level] (level 1 = 0): 0, 100, 300, 600, 1000…
int xpToReach(int level) => 50 * level * (level - 1);

int levelForXp(int xp) {
  int l = 1;
  while (xpToReach(l + 1) <= xp) {
    l++;
  }
  return l;
}

String rankName(int level) {
  if (level >= 25) return 'Legend';
  if (level >= 18) return 'Elite';
  if (level >= 12) return 'Veteran';
  if (level >= 7) return 'Committed';
  if (level >= 3) return 'Rising';
  return 'Rookie';
}

/// Unlockable accent themes. Index 0 is always available (auto = phase colour).
class ThemeSkin {
  final String id;
  final String name;
  final int unlockLevel;
  final int argb; // 0 = use the phase accent
  const ThemeSkin(this.id, this.name, this.unlockLevel, this.argb);
}

const List<ThemeSkin> kThemes = <ThemeSkin>[
  ThemeSkin('auto', 'Journey (auto)', 1, 0),
  ThemeSkin('ember', 'Ember', 3, 0xFFF0883C),
  ThemeSkin('mint', 'Mint', 6, 0xFF3CD6A3),
  ThemeSkin('violet', 'Violet', 10, 0xFFB44CF0),
  ThemeSkin('gold', 'Gold', 15, 0xFFF0C040),
  ThemeSkin('crimson', 'Crimson', 20, 0xFFE0435B),
];

/// The accent to actually paint with: an unlocked skin overrides the
/// journey-phase colour; 'auto' keeps the phase colour.
int skinArgb(String id) {
  for (final ThemeSkin s in kThemes) {
    if (s.id == id) return s.argb;
  }
  return 0;
}

/// Bronze → silver → gold trim, earned by how much of a lane is cleared.
String trimFor(int completedInLane) {
  if (completedInLane >= 12) return 'gold';
  if (completedInLane >= 6) return 'silver';
  if (completedInLane >= 2) return 'bronze';
  return '';
}

// ── challenges ──────────────────────────────────────────────────────────

class ChallengeDef {
  final String id;
  final String title;
  final String desc;
  final String emoji;
  final int days; // window length
  final int xp;
  final int unlockLevel;
  final bool auto; // verified from logged data vs an honour-system tap
  final int cooldownDays; // before it can be taken again
  const ChallengeDef({
    required this.id,
    required this.title,
    required this.desc,
    required this.emoji,
    required this.days,
    required this.xp,
    this.unlockLevel = 1,
    this.auto = false,
    this.cooldownDays = 7,
  });
}

const List<ChallengeDef> kChallenges = <ChallengeDef>[
  ChallengeDef(
      id: 'fast_day',
      title: 'Fast Day',
      desc: 'Fast for a full day',
      emoji: '⏳',
      days: 1,
      xp: kXpMed,
      auto: true),
  ChallengeDef(
      id: 'plant_day',
      title: 'Plant Day',
      desc: 'Go vegan for a day',
      emoji: '🌱',
      days: 1,
      xp: kXpSmall),
  ChallengeDef(
      id: 'hydrate',
      title: 'Hydrate',
      desc: 'Drink 8 cups of water today',
      emoji: '💧',
      days: 1,
      xp: kXpSmall),
  ChallengeDef(
      id: 'rainbow',
      title: 'Rainbow',
      desc: '5 different vegetables in a day',
      emoji: '🌈',
      days: 1,
      xp: kXpSmall),
  ChallengeDef(
      id: 'home_cooked',
      title: 'Home Cooked',
      desc: 'Cook instead of takeout',
      emoji: '🍳',
      days: 1,
      xp: kXpSmall),
  ChallengeDef(
      id: 'protein_perfect',
      title: 'Protein Perfect',
      desc: 'Hit protein every day for a week',
      emoji: '🥩',
      days: 7,
      xp: kXpBig,
      unlockLevel: 3,
      auto: true),
  ChallengeDef(
      id: 'sugar_detox',
      title: 'Sugar Detox',
      desc: 'Three days, sugar under 25 g',
      emoji: '🚫🍬',
      days: 3,
      xp: kXpBig,
      unlockLevel: 4,
      auto: true),
  ChallengeDef(
      id: 'fiber_full',
      title: 'Fiber Full',
      desc: 'Hit your fiber target 5 days',
      emoji: '🥦',
      days: 7,
      xp: kXpMed,
      unlockLevel: 5,
      auto: true),
  ChallengeDef(
      id: 'dry_week',
      title: 'Dry Week',
      desc: 'No alcohol for 7 days',
      emoji: '🚱',
      days: 7,
      xp: kXpBig,
      unlockLevel: 6,
      cooldownDays: 14),
  ChallengeDef(
      id: 'double_fast',
      title: 'Iron Will',
      desc: 'Two fast days in one week',
      emoji: '🧘',
      days: 7,
      xp: kXpBig,
      unlockLevel: 8,
      auto: true,
      cooldownDays: 14),
];

/// A challenge the user has taken on. [startedAt] is a 'YYYY-MM-DD' date.
class ChallengeRun {
  final String id;
  final String startedAt;
  final String? completedAt; // set when finished (auto or honour tap)
  const ChallengeRun(this.id, this.startedAt, [this.completedAt]);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'startedAt': startedAt,
        if (completedAt != null) 'completedAt': completedAt,
      };
  factory ChallengeRun.fromJson(Map<String, dynamic> j) => ChallengeRun(
        j['id'] as String,
        j['startedAt'] as String,
        j['completedAt'] as String?,
      );

  ChallengeRun complete(String date) => ChallengeRun(id, startedAt, date);
}

ChallengeDef? challengeDef(String id) {
  for (final ChallengeDef c in kChallenges) {
    if (c.id == id) return c;
  }
  return null;
}

// ── the computed state ──────────────────────────────────────────────────

class GoalState {
  final List<Goal> live; // one per lane (in Lane order)
  final List<Goal> completed;
  final List<Goal> all; // every goal across every lane
  final int xp;
  final int level;
  final int xpIntoLevel;
  final int xpForLevel;
  final String rank;
  final int currentStreak;
  final int bestStreak;
  final int freezeCapacity;
  final int freezesUsed;
  final List<ChallengeRun> active;
  final List<ChallengeDef> available;
  final List<ChallengeRun> finishedChallenges;
  final double journey; // 0..1 start weight → goal weight
  final double currentWeight;
  final double goalWeight;

  const GoalState({
    required this.live,
    required this.completed,
    required this.all,
    required this.xp,
    required this.level,
    required this.xpIntoLevel,
    required this.xpForLevel,
    required this.rank,
    required this.currentStreak,
    required this.bestStreak,
    required this.freezeCapacity,
    required this.freezesUsed,
    required this.active,
    required this.available,
    required this.finishedChallenges,
    required this.journey,
    required this.currentWeight,
    required this.goalWeight,
  });

  List<ThemeSkin> get unlockedThemes =>
      kThemes.where((ThemeSkin t) => t.unlockLevel <= level).toList();

  /// Repeatable wins that have actually fired (New Low ×3, PBs, …). They never
  /// "complete", so they earn by tally and show on the shelf with their count.
  List<Goal> get tallied =>
      all.where((Goal g) => g.repeatable && g.timesDone > 0).toList();

  int completedInLane(Lane l) =>
      completed.where((Goal g) => g.lane == l).length;

  /// Titles of wins finished in the last [days] — used by the coach.
  List<String> recentWins(int days) => <String>[
        for (final Goal g in completed.take(3)) g.title,
      ];
}

class GoalEngine {
  static GoalState compute(
    UserCalibration cal,
    List<DailyLog> logs,
    List<FoodEntry> foods,
    Set<String> fasted, {
    List<RunRecord> runs = const <RunRecord>[],
    List<SleepEntry> sleep = const <SleepEntry>[],
    int trainerLevel = 1,
    List<ChallengeRun> challenges = const <ChallengeRun>[],
    DateTime? asOf,
  }) {
    final DateTime now = asOf ?? DateTime.now();
    final MacroTargets t = MacroTargets.compute(cal, logs, foods, fasted);
    final Map<String, double> byDateCal = FoodMath.caloriesByDate(foods);
    final double tdee = logs.isEmpty
        ? 0
        : MathEngine.activeTdee(logs, cal.activityMult,
            caloriesByDate: byDateCal, fastedDates: fasted);

    final List<List<Goal>> lanes = <List<Goal>>[
      _weight(cal, logs),
      _body(cal, logs),
      _running(runs, trainerLevel, sleep, now),
      _nutrition(t, foods, byDateCal, tdee, now),
      _consistency(t, logs, foods, byDateCal, now),
      _sleepLane(sleep, logs, runs, cal, now),
    ];

    final List<Goal> live = <Goal>[];
    final List<Goal> completed = <Goal>[];
    final List<Goal> all = <Goal>[for (final List<Goal> l in lanes) ...l];
    for (final List<Goal> lane in lanes) {
      Goal? pick;
      for (final Goal g in lane) {
        if (g.done) {
          completed.add(g);
        } else {
          pick ??= g;
        }
      }
      // A lane that has cleared its whole ladder falls back to its repeatable,
      // so a lane is never empty however long the journey runs.
      pick ??= lane.lastWhere((Goal g) => g.repeatable,
          orElse: () => lane.isNotEmpty
              ? lane.last
              : const Goal(
                  id: 'none',
                  lane: Lane.weight,
                  title: 'All clear',
                  desc: 'Nothing pending here',
                  emoji: '✅',
                  xp: 0,
                  progress: 1,
                  done: true));
      live.add(pick);
    }

    // XP: every cleared goal, plus each firing of a repeatable one. Walk `all`
    // so a repeatable that is neither "live" nor "completed" still earns.
    int xp = 0;
    for (final Goal g in all) {
      if (g.repeatable) {
        xp += g.xp * g.timesDone;
      } else if (g.done) {
        xp += g.xp;
      }
    }
    final List<ChallengeRun> finished = challenges
        .where((ChallengeRun c) => c.completedAt != null)
        .toList();
    for (final ChallengeRun c in finished) {
      xp += challengeDef(c.id)?.xp ?? 0;
    }

    final int level = levelForXp(xp);
    final int base = xpToReach(level);
    final int next = xpToReach(level + 1);
    final int freezeCapacity = level ~/ 3;

    final Set<String> qualifying = _qualifyingDays(t, foods, byDateCal);
    final Set<String> allDates = <String>{
      ...byDateCal.keys,
      for (final DailyLog l in logs) l.date
    };
    final (int cur, int best, int used) =
        _streak(qualifying, allDates, now, freezeCapacity);

    // Challenge availability: unlocked by level, not already running, and off
    // cooldown since the last completion.
    final List<ChallengeRun> active = challenges
        .where((ChallengeRun c) => c.completedAt == null)
        .where((ChallengeRun c) => !_expired(c, now))
        .toList();
    final Set<String> activeIds =
        active.map((ChallengeRun c) => c.id).toSet();
    final List<ChallengeDef> available = <ChallengeDef>[];
    for (final ChallengeDef d in kChallenges) {
      if (d.unlockLevel > level || activeIds.contains(d.id)) {
        continue;
      }
      final Iterable<ChallengeRun> done =
          finished.where((ChallengeRun c) => c.id == d.id);
      if (done.isEmpty) {
        available.add(d);
        continue;
      }
      final String last = done
          .map((ChallengeRun c) => c.completedAt!)
          .reduce((String a, String b) => a.compareTo(b) > 0 ? a : b);
      final int since = now.difference(DateTime.parse(last)).inDays;
      if (since >= d.cooldownDays) {
        available.add(d);
      }
    }

    final double curW = logs.isEmpty ? cal.startWeight : logs.last.weight;
    final double goalW = logs.isEmpty
        ? cal.startWeight * (1 - cal.targetBf) / (1 - cal.startBf)
        : MathEngine.dynamicTargetWeight(logs.last.lbm, cal.targetBf);
    final double span = cal.startWeight - goalW;
    final double journey =
        span <= 0 ? 1 : ((cal.startWeight - curW) / span).clamp(0.0, 1.0);

    return GoalState(
      live: live,
      completed: completed,
      all: all,
      xp: xp,
      level: level,
      xpIntoLevel: xp - base,
      xpForLevel: next - base,
      rank: rankName(level),
      currentStreak: cur,
      bestStreak: best,
      freezeCapacity: freezeCapacity,
      freezesUsed: used,
      active: active,
      available: available,
      finishedChallenges: finished,
      journey: journey,
      currentWeight: curW,
      goalWeight: goalW,
    );
  }

  static bool _expired(ChallengeRun c, DateTime now) {
    final ChallengeDef? d = challengeDef(c.id);
    if (d == null) return true;
    final int age = now.difference(DateTime.parse(c.startedAt)).inDays;
    return age >= d.days + 1;
  }

  /// Is [run] satisfied by the logged data? Only for `auto` challenges.
  static bool challengeMet(
    ChallengeRun run,
    MacroTargets t,
    List<FoodEntry> foods,
    Set<String> fasted,
    DateTime now,
  ) {
    final ChallengeDef? d = challengeDef(run.id);
    if (d == null || !d.auto) return false;
    final DateTime start = DateTime.parse(run.startedAt);
    final List<String> window = <String>[
      for (int i = 0; i < d.days; i++)
        formatDate(start.add(Duration(days: i)))
    ];
    switch (run.id) {
      case 'fast_day':
        return window.any(fasted.contains);
      case 'double_fast':
        return window.where(fasted.contains).length >= 2;
      case 'protein_perfect':
        return window.every((String day) {
          final DayTotals dt = FoodMath.totals(foods, day);
          return t.protein > 0 && dt.protein >= t.protein * 0.9;
        });
      case 'sugar_detox':
        return window.every((String day) {
          final DayTotals dt = FoodMath.totals(foods, day);
          return dt.calories > 0 && (dt.nutrients['sugars'] ?? 0) < 25;
        });
      case 'fiber_full':
        return window.where((String day) {
              final DayTotals dt = FoodMath.totals(foods, day);
              return t.fiber > 0 && (dt.nutrients['fiber'] ?? 0) >= t.fiber;
            }).length >=
            5;
      default:
        return false;
    }
  }

  // ── lane: weight ──────────────────────────────────────────────────────
  static List<Goal> _weight(UserCalibration cal, List<DailyLog> logs) {
    if (logs.isEmpty) {
      return <Goal>[
        const Goal(
            id: 'w_first',
            lane: Lane.weight,
            title: 'First Weigh-In',
            desc: 'Log your weight to start the journey',
            emoji: '⚖️',
            xp: kXpSmall,
            progress: 0,
            done: false),
      ];
    }
    final double start = cal.startWeight;
    final double cur = logs.last.weight;
    final double lowest =
        logs.map((DailyLog l) => l.weight).reduce((double a, double b) => min(a, b));
    final double goalW =
        MathEngine.dynamicTargetWeight(logs.last.lbm, cal.targetBf);

    final List<Goal> out = <Goal>[
      Goal(
          id: 'w_first',
          lane: Lane.weight,
          title: 'First Weigh-In',
          desc: 'The journey starts',
          emoji: '⚖️',
          xp: kXpSmall,
          progress: 1,
          done: true),
    ];

    // Descending round-5 checkpoints from just under the start weight down to
    // the goal — the "get under 190" ladder, generated to fit any journey.
    for (double tgt = (start / 5).floorToDouble() * 5;
        tgt > goalW + 0.5;
        tgt -= 5) {
      if (tgt >= start) continue;
      final bool done = lowest <= tgt;
      out.add(Goal(
        id: 'w_under_${tgt.round()}',
        lane: Lane.weight,
        title: 'Get under ${tgt.round()}',
        desc: done
            ? 'Cleared'
            : '${(cur - tgt).toStringAsFixed(1)} lb to go',
        emoji: '🎯',
        xp: kXpMed,
        progress: ((start - cur) / max(start - tgt, 0.001)).clamp(0.0, 1.0),
        done: done,
      ));
      // Halfway lands inside the ladder where it belongs.
      final double half = start - (start - goalW) / 2;
      if (tgt <= half && tgt > half - 5) {
        final bool hd = lowest <= half;
        out.add(Goal(
          id: 'w_halfway',
          lane: Lane.weight,
          title: 'Halfway There',
          desc: hd
              ? 'Half the journey done'
              : '${(cur - half).toStringAsFixed(1)} lb to the midpoint',
          emoji: '🪜',
          xp: kXpBig,
          progress: ((start - cur) / max(start - half, 0.001)).clamp(0.0, 1.0),
          done: hd,
        ));
      }
    }

    out.add(Goal(
      id: 'w_goal',
      lane: Lane.weight,
      title: 'Goal Weight',
      desc: lowest <= goalW
          ? 'You did it'
          : '${(cur - goalW).toStringAsFixed(1)} lb to go',
      emoji: '🏆',
      xp: kXpHuge,
      progress: ((start - cur) / max(start - goalW, 0.001)).clamp(0.0, 1.0),
      done: lowest <= goalW,
    ));

    // Repeatable: every time a weigh-in sets a new all-time low.
    int lows = 0;
    double running = double.infinity;
    for (final DailyLog l in logs) {
      if (l.weight < running) {
        if (running != double.infinity) lows++;
        running = l.weight;
      }
    }
    out.add(Goal(
      id: 'w_new_low',
      lane: Lane.weight,
      title: 'New Low',
      desc: cur <= lowest + 0.001
          ? 'You are at your lowest yet'
          : 'Beat ${lowest.toStringAsFixed(1)} lb',
      emoji: '📉',
      xp: kXpSmall,
      progress: (lowest / max(cur, 0.001)).clamp(0.0, 1.0),
      done: false,
      timesDone: lows,
      repeatable: true,
    ));
    return out;
  }

  // ── lane: body composition ────────────────────────────────────────────
  static List<Goal> _body(UserCalibration cal, List<DailyLog> logs) {
    if (logs.isEmpty) {
      return <Goal>[
        const Goal(
            id: 'b_first',
            lane: Lane.body,
            title: 'Baseline',
            desc: 'Log body-fat to unlock this lane',
            emoji: '🧬',
            xp: kXpSmall,
            progress: 0,
            done: false),
      ];
    }
    final double startBf = cal.startBf * 100;
    final double curBf = logs.last.bf * 100;
    final double lowBf = logs
        .map((DailyLog l) => l.bf * 100)
        .reduce((double a, double b) => min(a, b));
    final double targetBf = cal.targetBf * 100;
    final List<Goal> out = <Goal>[];

    for (double tgt = startBf.floorToDouble(); tgt >= targetBf; tgt -= 1) {
      if (tgt >= startBf) continue;
      final bool done = lowBf <= tgt;
      out.add(Goal(
        id: 'b_under_${tgt.round()}',
        lane: Lane.body,
        title: 'Under ${tgt.round()}% body fat',
        desc: done
            ? 'Cleared'
            : '${(curBf - tgt).toStringAsFixed(1)} pts to go',
        emoji: '🧬',
        xp: kXpMed,
        progress:
            ((startBf - curBf) / max(startBf - tgt, 0.001)).clamp(0.0, 1.0),
        done: done,
      ));
    }

    // Recomp reads over the last ~4 weeks of logs.
    final int n = logs.length;
    final DailyLog first = logs[max(0, n - 28)];
    final double dLean = logs.last.lbm - first.lbm;
    final double dFat = logs.last.fatMass - first.fatMass;
    out.add(Goal(
      id: 'b_muscle_intact',
      lane: Lane.body,
      title: 'Muscle Intact',
      desc: 'Lose fat while holding lean mass',
      emoji: '💪',
      xp: kXpBig,
      progress: dFat < 0 ? 0.6 : 0.2,
      done: n >= 14 && dFat < -0.5 && dLean >= -0.2,
    ));
    out.add(Goal(
      id: 'b_built_different',
      lane: Lane.body,
      title: 'Built Different',
      desc: 'Lean mass up while fat goes down',
      emoji: '🏗️',
      xp: kXpBig,
      progress: dLean > 0 ? 0.6 : 0.2,
      done: n >= 14 && dFat < -0.5 && dLean > 0.5,
    ));
    return out;
  }

  // ── lane: running ─────────────────────────────────────────────────────
  static List<Goal> _running(List<RunRecord> runs, int trainerLevel,
      List<SleepEntry> sleep, DateTime now) {
    final int count = runs.length;
    final double totalKm =
        runs.fold<double>(0, (double a, RunRecord r) => a + r.distanceKm);
    final double longestKm = runs.isEmpty
        ? 0
        : runs.map((RunRecord r) => r.distanceKm).reduce(max);
    final int longestSec = runs.isEmpty
        ? 0
        : runs.map((RunRecord r) => r.durationSec).reduce(max);

    final Set<String> dates = runs.map((RunRecord r) => r.date).toSet();
    final String weekAgo = formatDate(now.subtract(const Duration(days: 7)));
    final int thisWeek =
        dates.where((String d) => d.compareTo(weekAgo) > 0).length;
    bool backToBack = false;
    for (final String d in dates) {
      final String nextDay =
          formatDate(DateTime.parse(d).add(const Duration(days: 1)));
      if (dates.contains(nextDay)) backToBack = true;
    }
    bool weekendWarrior = false;
    for (final String d in dates) {
      final DateTime dt = DateTime.parse(d);
      if (dt.weekday == DateTime.saturday &&
          dates.contains(formatDate(dt.add(const Duration(days: 1))))) {
        weekendWarrior = true;
      }
    }
    final bool cruise = runs.any((RunRecord r) {
      final double? resting = SleepMath.baselineRestingHr(sleep, now);
      return r.avgHr != null &&
          resting != null &&
          resting > 0 &&
          (r.avgHr! - resting) <= 70;
    });

    Goal g(String id, String title, String desc, String emoji, int xp,
            bool done, double prog) =>
        Goal(
            id: id,
            lane: Lane.running,
            title: title,
            desc: desc,
            emoji: emoji,
            xp: xp,
            progress: prog.clamp(0.0, 1.0),
            done: done);

    final List<Goal> out = <Goal>[
      g('r_lace_up', 'Lace Up', 'Log your first run', '👟', kXpSmall,
          count >= 1, count / 1),
      g('r_two_timer', 'Two-Timer', 'Run twice in one week', '✌️', kXpSmall,
          thisWeek >= 2, thisWeek / 2),
      g('r_first_mile', 'First Mile', 'Cover a mile in one run', '📏', kXpMed,
          longestKm >= 1.609, longestKm / 1.609),
      g('r_back_to_back', 'Back-to-Back', 'Run two days in a row', '🔗',
          kXpMed, backToBack, backToBack ? 1 : 0.3),
      g('r_hat_trick', 'Hat Trick', 'Three runs in a week', '🎩', kXpMed,
          thisWeek >= 3, thisWeek / 3),
      g('r_weekend', 'Weekend Warrior', 'Run Saturday and Sunday', '🗓️',
          kXpMed, weekendWarrior, weekendWarrior ? 1 : 0.3),
      g('r_10km', 'Ten Down', '10 km logged all-time', '🔟', kXpMed,
          totalKm >= 10, totalKm / 10),
      g('r_five_straight', 'Five Straight', 'Reach trainer level 5', '🪜',
          kXpMed, trainerLevel >= 5, trainerLevel / 5),
      g('r_cruise', 'Cruise Control', 'Finish a run in your easy zone', '😌',
          kXpMed, cruise, cruise ? 1 : 0.3),
      g('r_25km', 'Quarter Century', '25 km logged all-time', '🏅', kXpMed,
          totalKm >= 25, totalKm / 25),
      g('r_5k_dist', '5K Distance', 'Cover 5 km in one outing', '🏁', kXpBig,
          longestKm >= 5, longestKm / 5),
      g('r_no_walking', 'No More Walking', 'Reach level 8 — run unbroken',
          '🚶‍♂️❌', kXpBig, trainerLevel >= 8, trainerLevel / 8),
      g('r_50km', 'Fifty Club', '50 km logged all-time', '🛣️', kXpBig,
          totalKm >= 50, totalKm / 50),
      g('r_twenty_straight', 'Twenty Straight', 'Run 20 minutes unbroken',
          '⏱️', kXpBig, longestSec >= 1200, longestSec / 1200),
      g('r_the_5k', 'The 5K', '30 minutes continuous', '🏆', kXpHuge,
          trainerLevel >= 11, trainerLevel / 11),
      g('r_100km', 'Century Club', '100 km logged all-time', '💯', kXpBig,
          totalKm >= 100, totalKm / 100),
      g('r_marathon', 'The Long Way', '42 km logged, one run at a time', '🎖️',
          kXpHuge, totalKm >= 42.2, totalKm / 42.2),
    ];
    out.add(Goal(
      id: 'r_pb',
      lane: Lane.running,
      title: 'Personal Best',
      desc: longestKm > 0
          ? 'Beat ${longestKm.toStringAsFixed(1)} km'
          : 'Set your first distance',
      emoji: '🚀',
      xp: kXpSmall,
      progress: 0.5,
      done: false,
      timesDone: count > 1 ? _pbCount(runs) : 0,
      repeatable: true,
    ));
    return out;
  }

  static int _pbCount(List<RunRecord> runs) {
    final List<RunRecord> sorted = List<RunRecord>.of(runs)
      ..sort((RunRecord a, RunRecord b) => a.date.compareTo(b.date));
    double best = 0;
    int n = 0;
    for (final RunRecord r in sorted) {
      if (r.distanceKm > best) {
        if (best > 0) n++;
        best = r.distanceKm;
      }
    }
    return n;
  }

  // ── lane: nutrition (weekly, so it always refreshes) ──────────────────
  static List<Goal> _nutrition(MacroTargets t, List<FoodEntry> foods,
      Map<String, double> byDateCal, double tdee, DateTime now) {
    int proteinDays = 0, fiberDays = 0, deficitDays = 0;
    for (int i = 0; i < 7; i++) {
      final String d = formatDate(now.subtract(Duration(days: i)));
      if ((byDateCal[d] ?? 0) <= 0) continue;
      final DayTotals dt = FoodMath.totals(foods, d);
      if (t.protein > 0 && dt.protein >= t.protein * 0.9) proteinDays++;
      if (t.fiber > 0 && (dt.nutrients['fiber'] ?? 0) >= t.fiber) fiberDays++;
      if (tdee > 0 && dt.calories < tdee) deficitDays++;
    }
    Goal g(String id, String title, String desc, String emoji, int have,
            int need, int xp) =>
        Goal(
            id: id,
            lane: Lane.nutrition,
            title: title,
            desc: '$have/$need this week',
            emoji: emoji,
            xp: xp,
            progress: (have / need).clamp(0.0, 1.0),
            done: have >= need,
            repeatable: true,
            timesDone: 0);
    return <Goal>[
      g('n_protein_3', 'Protein x3', '', '🥩', proteinDays, 3, kXpSmall),
      g('n_deficit_4', 'Four in Deficit', '', '🔥', deficitDays, 4, kXpSmall),
      g('n_fiber_3', 'Fiber x3', '', '🥦', fiberDays, 3, kXpSmall),
      g('n_protein_5', 'Protein x5', '', '💪', proteinDays, 5, kXpMed),
      g('n_deficit_6', 'Six in Deficit', '', '🎯', deficitDays, 6, kXpMed),
      g('n_protein_7', 'Perfect Protein Week', '', '🏆', proteinDays, 7,
          kXpBig),
    ];
  }

  // ── lane: consistency ─────────────────────────────────────────────────
  static List<Goal> _consistency(MacroTargets t, List<DailyLog> logs,
      List<FoodEntry> foods, Map<String, double> byDateCal, DateTime now) {
    final Set<String> qualifying = _qualifyingDays(t, foods, byDateCal);
    final Set<String> allDates = <String>{
      ...byDateCal.keys,
      for (final DailyLog l in logs) l.date
    };
    final (int cur, int best, _) = _streak(qualifying, allDates, now, 0);
    final int logged = allDates.length;

    // A perfect day: weight + food logged, protein hit.
    final Set<String> weightDates = <String>{for (final DailyLog l in logs) l.date};
    int perfect = 0;
    for (final String d in qualifying) {
      if (weightDates.contains(d)) perfect++;
    }

    Goal g(String id, String title, String desc, String emoji, int have,
            int need, int xp) =>
        Goal(
            id: id,
            lane: Lane.consistency,
            title: title,
            desc: '$have/$need',
            emoji: emoji,
            xp: xp,
            progress: (have / need).clamp(0.0, 1.0),
            done: have >= need);
    return <Goal>[
      g('c_first', 'First Step', 'Log your first day', '👣', logged, 1,
          kXpSmall),
      g('c_perfect', 'Perfect Day', 'Weight + food + protein', '✨', perfect, 1,
          kXpSmall),
      g('c_streak_3', 'Three in a Row', '', '🔥', best, 3, kXpSmall),
      g('c_log_7', 'First Week', '', '📅', logged, 7, kXpSmall),
      g('c_streak_7', 'Seven-Day Streak', '', '🔥', best, 7, kXpMed),
      g('c_log_30', 'Locked In', '', '🔒', logged, 30, kXpMed),
      g('c_streak_14', 'Two-Week Warrior', '', '⚡', best, 14, kXpBig),
      g('c_perfect_10', 'Ten Perfect Days', '', '✨', perfect, 10, kXpMed),
      g('c_streak_30', 'Unstoppable', '', '🌟', best, 30, kXpBig),
      g('c_log_100', 'Century', '', '💯', logged, 100, kXpBig),
      g('c_streak_60', 'Iron Habit', '', '🛡️', best, 60, kXpBig),
      g('c_streak_100', 'Hundred-Day Streak', '', '👑', best, 100, kXpHuge),
    ];
  }

  // ── lane: sleep ───────────────────────────────────────────────────────
  static List<Goal> _sleepLane(List<SleepEntry> sleep, List<DailyLog> logs,
      List<RunRecord> runs, UserCalibration cal, DateTime now) {
    final List<SleepEntry> sorted = List<SleepEntry>.of(sleep)
      ..sort((SleepEntry a, SleepEntry b) => a.date.compareTo(b.date));
    final int good = sorted.where((SleepEntry e) => e.hours >= 7).length;
    int bestRun = 0, run = 0;
    String? prev;
    for (final SleepEntry e in sorted) {
      final bool consecutive = prev != null &&
          DateTime.parse(e.date).difference(DateTime.parse(prev)).inDays == 1;
      run = (e.hours >= 7) ? (consecutive ? run + 1 : 1) : 0;
      bestRun = max(bestRun, run);
      prev = e.date;
    }
    final SleepEntry? last = SleepMath.latest(sleep);
    final Readiness? r = last == null
        ? null
        : computeReadiness(
            lastNightHours: last.hours,
            baselineHours: SleepMath.baselineHours(sleep, now),
            runsLast7: runsThisWeek(runs, now),
            deficit: cal.deficit,
            restingHr: last.restingHr,
            baselineRestingHr: SleepMath.baselineRestingHr(sleep, now),
            hrv: last.hrv,
            baselineHrv: SleepMath.baselineHrv(sleep, now));

    Goal g(String id, String title, String desc, String emoji, int have,
            int need, int xp) =>
        Goal(
            id: id,
            lane: Lane.sleep,
            title: title,
            desc: '$have/$need',
            emoji: emoji,
            xp: xp,
            progress: (have / need).clamp(0.0, 1.0),
            done: have >= need);
    return <Goal>[
      g('s_first', 'Well Rested', 'A 7-hour night', '😴', good, 1, kXpSmall),
      g('s_three', 'Recharged', 'Three 7h nights in a row', '🔋', bestRun, 3,
          kXpMed),
      g('s_ready', 'Recovery Mode', 'A high-readiness morning', '🌤️',
          (r?.score ?? 0) >= 80 ? 1 : 0, 1, kXpMed),
      g('s_seven', 'Rested Week', 'Seven 7h nights', '🛌', good, 7, kXpMed),
      g('s_five_row', 'Sleep Streak', 'Five 7h nights in a row', '🌙', bestRun,
          5, kXpBig),
      g('s_thirty', 'Sleep Champion', 'Thirty 7h nights', '👑', good, 30,
          kXpBig),
    ];
  }

  // ── shared ────────────────────────────────────────────────────────────

  /// A day "counts" for the streak when food was logged and protein was hit —
  /// the one habit that protects muscle while cutting.
  static Set<String> _qualifyingDays(
      MacroTargets t, List<FoodEntry> foods, Map<String, double> byDateCal) {
    final Set<String> out = <String>{};
    for (final MapEntry<String, double> e in byDateCal.entries) {
      if (e.value <= 0) continue;
      final DayTotals dt = FoodMath.totals(foods, e.key);
      if (t.protein > 0 && dt.protein >= t.protein * 0.9) {
        out.add(e.key);
      }
    }
    return out;
  }

  /// Forgiving streak. One missed day never breaks it; a second consecutive
  /// miss spends an earned freeze; a third ends it.
  static (int, int, int) _streak(Set<String> qualifying, Set<String> allDates,
      DateTime now, int freezeCapacity) {
    if (qualifying.isEmpty) return (0, 0, 0);
    DateTime? first;
    for (final String d in allDates) {
      final DateTime dt = DateTime.parse(d);
      if (first == null || dt.isBefore(first)) first = dt;
    }
    final DateTime today = DateTime(now.year, now.month, now.day);
    int best = 0, run = 0, gap = 0, cur = 0, freezes = freezeCapacity, used = 0;
    bool alive = false;
    for (DateTime d = first!; !d.isAfter(today); d = d.add(const Duration(days: 1))) {
      if (qualifying.contains(formatDate(d))) {
        run++;
        gap = 0;
        best = max(best, run);
        cur = run;
        alive = true;
      } else {
        gap++;
        if (gap == 2) {
          if (freezes > 0) {
            freezes--;
            used++;
          } else {
            run = 0;
            alive = false;
          }
        } else if (gap >= 3) {
          run = 0;
          alive = false;
        }
      }
    }
    return (alive ? cur : 0, best, used);
  }
}
