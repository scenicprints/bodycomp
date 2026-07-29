import 'main.dart';
import 'food.dart';
import 'sleep.dart';
import 'trainer.dart';

// ═══════════════════════════════════════════════════════════════════════
// PROGRESS / GAME LAYER — XP, levels, forgiving streaks, and achievements.
//
// Everything is DERIVED from the user's real history (weight/fat/lean, food,
// runs, sleep) — pure and deterministic, so it's unit-testable and can't be
// gamed or drift. The only thing that needs persisting is which achievements
// the user has already SEEN (so a fresh unlock can be celebrated once).
//
// Design rule, matching the coach: this REWARDS, it never nags. Missed or
// unlogged days simply earn nothing — they are never counted against you, and
// a single off day never breaks a streak.
// ═══════════════════════════════════════════════════════════════════════

// XP awards (tunable). Outcomes pay the most; good daily habits pay steadily.
const int kXpPerFatLb = 120; // per lb of fat mass lost vs start
const int kXpPerLeanLb = 100; // per lb of lean mass gained vs start
const int kXpGoalTier = 250; // each 25% of the way to goal body-fat
const int kXpLogWeight = 5;
const int kXpLogFood = 5;
const int kXpProtein = 15; // hit protein that day
const int kXpFiber = 8;
const int kXpDeficit = 10;
const int kXpRun = 25;
const int kXpSleep = 8; // slept 7h+

/// Cumulative XP needed to REACH [level] (level 1 = 0). Each level costs 100
/// more than the last: 0, 100, 300, 600, 1000, …
int xpToReach(int level) => 50 * level * (level - 1);

int levelForXp(int xp) {
  int l = 1;
  while (xpToReach(l + 1) <= xp) {
    l++;
  }
  return l;
}

String rankName(int level) {
  if (level >= 20) return 'Legend';
  if (level >= 15) return 'Elite';
  if (level >= 10) return 'Veteran';
  if (level >= 6) return 'Committed';
  if (level >= 3) return 'Rising';
  return 'Rookie';
}

/// One badge. [progress] is 0..1 toward unlocking, for the locked-state hint.
class Achievement {
  final String id;
  final String title;
  final String desc;
  final String emoji;
  final bool unlocked;
  final double progress;
  const Achievement({
    required this.id,
    required this.title,
    required this.desc,
    required this.emoji,
    required this.unlocked,
    required this.progress,
  });
}

class GameStats {
  final int xp;
  final int level;
  final int xpIntoLevel; // XP earned within the current level
  final int xpForLevel; // XP span of the current level
  final String rank;

  final int currentStreak;
  final int bestStreak;

  // Aggregate counters (also drive achievements).
  final int daysLogged;
  final int proteinHitDays;
  final int fiberHitDays;
  final int deficitDays;
  final int runsCount;
  final int goodSleepNights;
  final double fatLostLb;
  final double leanDeltaLb;
  final double goalProgress; // 0..1 to target body-fat
  final int trainerLevel;

  final List<Achievement> achievements;

  const GameStats({
    required this.xp,
    required this.level,
    required this.xpIntoLevel,
    required this.xpForLevel,
    required this.rank,
    required this.currentStreak,
    required this.bestStreak,
    required this.daysLogged,
    required this.proteinHitDays,
    required this.fiberHitDays,
    required this.deficitDays,
    required this.runsCount,
    required this.goodSleepNights,
    required this.fatLostLb,
    required this.leanDeltaLb,
    required this.goalProgress,
    required this.trainerLevel,
    required this.achievements,
  });

  int get unlockedCount =>
      achievements.where((Achievement a) => a.unlocked).length;

  static GameStats compute(
    UserCalibration cal,
    List<DailyLog> logs,
    List<FoodEntry> foods,
    Set<String> fasted, {
    List<RunRecord> runs = const <RunRecord>[],
    List<SleepEntry> sleep = const <SleepEntry>[],
    int trainerLevel = 0,
    DateTime? asOf,
  }) {
    final DateTime now = asOf ?? DateTime.now();
    final MacroTargets t = MacroTargets.compute(cal, logs, foods, fasted);
    final Map<String, double> byDateCal = FoodMath.caloriesByDate(foods);
    final double tdee = logs.isEmpty
        ? 0
        : MathEngine.activeTdee(logs, cal.activityMult,
            caloriesByDate: byDateCal, fastedDates: fasted);

    final Map<String, DailyLog> logByDate = <String, DailyLog>{
      for (final DailyLog l in logs) l.date: l
    };
    final Set<String> runDates = <String>{for (final RunRecord r in runs) r.date};
    final Map<String, SleepEntry> sleepByDate = <String, SleepEntry>{
      for (final SleepEntry e in sleep) e.date: e
    };

    // All calendar days that carry any data.
    final Set<String> dates = <String>{...logByDate.keys, ...byDateCal.keys};

    int xp = 0;
    int daysLogged = 0,
        proteinHitDays = 0,
        fiberHitDays = 0,
        deficitDays = 0,
        goodSleepNights = 0;
    final Set<String> qualifying = <String>{}; // streak days: food + protein

    for (final String d in dates) {
      final bool hasWeight = logByDate.containsKey(d);
      final double cals = byDateCal[d] ?? 0;
      final bool hasFood = cals > 0;
      if (!hasWeight && !hasFood) {
        continue;
      }
      daysLogged++;
      if (hasWeight) xp += kXpLogWeight;
      if (hasFood) {
        xp += kXpLogFood;
        final DayTotals dt = FoodMath.totals(foods, d);
        final bool proteinHit = t.protein > 0 && dt.protein >= t.protein * 0.9;
        if (proteinHit) {
          xp += kXpProtein;
          proteinHitDays++;
          qualifying.add(d);
        }
        if (t.fiber > 0 && (dt.nutrients['fiber'] ?? 0) >= t.fiber) {
          xp += kXpFiber;
          fiberHitDays++;
        }
        if (tdee > 0 && dt.calories < tdee) {
          xp += kXpDeficit;
          deficitDays++;
        }
      }
      if (runDates.contains(d)) xp += kXpRun;
      final SleepEntry? s = sleepByDate[d];
      if (s != null && s.hours >= 7) {
        xp += kXpSleep;
        goodSleepNights++;
      }
    }

    // Outcome XP — the big, satisfying rewards.
    final double fatLost =
        logs.isEmpty ? 0 : (cal.startFatMass - logs.last.fatMass);
    final double fatLostLb = fatLost > 0 ? fatLost : 0;
    final double leanDelta = logs.isEmpty ? 0 : (logs.last.lbm - cal.startLbm);
    final double leanGain = leanDelta > 0 ? leanDelta : 0;
    final double goalProgress = logs.isEmpty
        ? 0
        : MathEngine.progress(cal.startBf, logs.last.bf, cal.targetBf)
            .clamp(0.0, 1.0);
    final int goalTiers = <double>[0.25, 0.5, 0.75, 1.0]
        .where((double x) => goalProgress >= x)
        .length;

    xp += (fatLostLb * kXpPerFatLb).round();
    xp += (leanGain * kXpPerLeanLb).round();
    xp += goalTiers * kXpGoalTier;

    final int level = levelForXp(xp);
    final int base = xpToReach(level);
    final int next = xpToReach(level + 1);

    final (int cur, int best) = _streaks(dates, qualifying, now);
    final int runsCount = runs.length;

    final GameStats partial = GameStats(
      xp: xp,
      level: level,
      xpIntoLevel: xp - base,
      xpForLevel: next - base,
      rank: rankName(level),
      currentStreak: cur,
      bestStreak: best,
      daysLogged: daysLogged,
      proteinHitDays: proteinHitDays,
      fiberHitDays: fiberHitDays,
      deficitDays: deficitDays,
      runsCount: runsCount,
      goodSleepNights: goodSleepNights,
      fatLostLb: fatLostLb,
      leanDeltaLb: leanDelta,
      goalProgress: goalProgress,
      trainerLevel: trainerLevel,
      achievements: const <Achievement>[],
    );

    return GameStats(
      xp: partial.xp,
      level: partial.level,
      xpIntoLevel: partial.xpIntoLevel,
      xpForLevel: partial.xpForLevel,
      rank: partial.rank,
      currentStreak: partial.currentStreak,
      bestStreak: partial.bestStreak,
      daysLogged: partial.daysLogged,
      proteinHitDays: partial.proteinHitDays,
      fiberHitDays: partial.fiberHitDays,
      deficitDays: partial.deficitDays,
      runsCount: partial.runsCount,
      goodSleepNights: partial.goodSleepNights,
      fatLostLb: partial.fatLostLb,
      leanDeltaLb: partial.leanDeltaLb,
      goalProgress: partial.goalProgress,
      trainerLevel: partial.trainerLevel,
      achievements: _achievements(partial),
    );
  }

  // Forgiving streak: a single non-qualifying day between two qualifying days
  // doesn't break the chain; two misses in a row does. Streak length counts
  // qualifying days only.
  static (int, int) _streaks(
      Set<String> allDates, Set<String> qualifying, DateTime now) {
    if (qualifying.isEmpty) {
      return (0, 0);
    }
    // Walk the full calendar from the first data day to today.
    DateTime? first;
    for (final String d in allDates) {
      final DateTime dt = DateTime.parse(d);
      if (first == null || dt.isBefore(first)) first = dt;
    }
    final DateTime start = first!;
    final DateTime today = DateTime(now.year, now.month, now.day);

    int best = 0, run = 0, gap = 0, curAtEnd = 0;
    bool endedRecently = false;
    for (DateTime d = start;
        !d.isAfter(today);
        d = d.add(const Duration(days: 1))) {
      final String key = formatDate(d);
      if (qualifying.contains(key)) {
        run++;
        gap = 0;
        if (run > best) best = run;
        curAtEnd = run;
        endedRecently = true;
      } else {
        gap++;
        if (gap >= 2) {
          run = 0;
          endedRecently = false;
        }
      }
    }
    // Current streak only counts if the chain reached the last day or two.
    final int current = endedRecently ? curAtEnd : 0;
    return (current, best);
  }

  static List<Achievement> _achievements(GameStats s) {
    Achievement a(String id, String title, String desc, String emoji,
        bool unlocked, double progress) {
      return Achievement(
          id: id,
          title: title,
          desc: desc,
          emoji: emoji,
          unlocked: unlocked,
          progress: progress.clamp(0.0, 1.0));
    }

    double p(num have, num need) => need <= 0 ? 0 : have / need;

    return <Achievement>[
      a('first_log', 'First Step', 'Log your first day', '👟',
          s.daysLogged >= 1, p(s.daysLogged, 1)),
      a('log_7', 'Getting Serious', 'Log 7 days', '📅', s.daysLogged >= 7,
          p(s.daysLogged, 7)),
      a('log_30', 'Locked In', 'Log 30 days', '🔒', s.daysLogged >= 30,
          p(s.daysLogged, 30)),
      a('log_100', 'Century', 'Log 100 days', '💯', s.daysLogged >= 100,
          p(s.daysLogged, 100)),
      a('protein_week', 'Protein Week', 'Hit protein 7 days in a row', '🥩',
          s.bestStreak >= 7, p(s.bestStreak, 7)),
      a('protein_100', 'Protein Machine', 'Hit protein on 100 days', '💪',
          s.proteinHitDays >= 100, p(s.proteinHitDays, 100)),
      a('streak_14', 'Two-Week Warrior', 'A 14-day streak', '🔥',
          s.bestStreak >= 14, p(s.bestStreak, 14)),
      a('streak_30', 'Unstoppable', 'A 30-day streak', '⚡',
          s.bestStreak >= 30, p(s.bestStreak, 30)),
      a('fat_5', 'Fat Fighter', 'Lose 5 lb of fat', '🥊', s.fatLostLb >= 5,
          p(s.fatLostLb, 5)),
      a('fat_10', 'Down Ten', 'Lose 10 lb of fat', '📉', s.fatLostLb >= 10,
          p(s.fatLostLb, 10)),
      a('fat_20', 'Transformed', 'Lose 20 lb of fat', '🦋', s.fatLostLb >= 20,
          p(s.fatLostLb, 20)),
      a('lean_gain', 'Building', 'Gain 2 lb of lean mass', '🏗️',
          s.leanDeltaLb >= 2, p(s.leanDeltaLb, 2)),
      a('deficit_14', 'Discipline', '14 days in a deficit', '🎯',
          s.deficitDays >= 14, p(s.deficitDays, 14)),
      a('run_1', 'Runner', 'Log your first run', '🏃', s.runsCount >= 1,
          p(s.runsCount, 1)),
      a('run_10', 'Regular', 'Log 10 runs', '🏅', s.runsCount >= 10,
          p(s.runsCount, 10)),
      a('run_25', 'Road Warrior', 'Log 25 runs', '🛣️', s.runsCount >= 25,
          p(s.runsCount, 25)),
      a('sleep_7', 'Well Rested', '7 nights of 7h+ sleep', '😴',
          s.goodSleepNights >= 7, p(s.goodSleepNights, 7)),
      a('level_5', 'Level 5', 'Reach level 5', '⭐', s.level >= 5,
          p(s.level, 5)),
      a('level_10', 'Level 10', 'Reach level 10', '🌟', s.level >= 10,
          p(s.level, 10)),
      a('goal_25', 'Quarter Way', '25% to your goal', '🌱',
          s.goalProgress >= 0.25, p(s.goalProgress, 0.25)),
      a('goal_50', 'Halfway', '50% to your goal', '🌿',
          s.goalProgress >= 0.5, p(s.goalProgress, 0.5)),
      a('goal_75', 'Home Stretch', '75% to your goal', '🌳',
          s.goalProgress >= 0.75, p(s.goalProgress, 0.75)),
      a('goal_100', 'Goal Reached', 'Hit your target body-fat', '🏆',
          s.goalProgress >= 1.0, p(s.goalProgress, 1.0)),
    ];
  }
}
