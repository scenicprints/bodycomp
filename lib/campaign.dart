import 'dart:math';

import 'main.dart';
import 'food.dart';
import 'sleep.dart';
import 'trainer.dart';

// ═══════════════════════════════════════════════════════════════════════
// CAMPAIGN — the fight is your deficit.
//
// Pure, deterministic simulation in the GoalEngine mold: given the same
// history it always produces the same battle, so nothing is stored except
// the campaign start date. Every number is real:
//   • your damage      = TDEE − what you ate (capped so starving pays 0)
//   • enemy HP         = multiples of your TDEE, frozen at spawn
//   • the weekend boss = beat your own average unlogged-day weight gain
//   • the final boss   = the fat mass between you and your target BF%
//
// Weekends are a different game: Sat/Sun suspend all logging rules (the
// user's real life happens there, by design), the weekday enemy freezes,
// and the boss weighs you Monday morning.
// ═══════════════════════════════════════════════════════════════════════

// ── tuning ──────────────────────────────────────────────────────────────

const double kIntakeFloor = 1200; // damage capped at TDEE − this
const double kUnloggedHit = 20; // silent weekday
const double kCheatHit = 15;
const double kCheatSlackLb = 1.5; // scale-vs-log disagreement to fire
const int kCheatWindow = 7;
const double kDefaultUnloggedGain = 0.35; // lb/day until history exists
const double kDefaultTdee = 2400; // only before any data exists
const double kRunAttackMin = 50; // extra kcal before a run lands a hit
const int kBossWinXp = 250;

// ── the roster ──────────────────────────────────────────────────────────

class ZoneDef {
  final String name;
  final String tagline;
  const ZoneDef(this.name, this.tagline);
}

const List<ZoneDef> kZones = <ZoneDef>[
  ZoneDef('The Pantry Shallows', 'Where every journey starts'),
  ZoneDef('Snackfang Woods', 'It is always somebody\'s birthday'),
  ZoneDef('The Graze Plains', 'Nothing here sits down to eat'),
  ZoneDef('Midnight Kitchen', 'The fridge light knows your name'),
  ZoneDef('The Buffet Barrens', 'One plate was never the deal'),
  ZoneDef('Plateau Peaks', 'The scale stopped talking to you'),
];

class EnemyDef {
  final int index; // absolute position on the road
  final String name;
  final String flavor;
  final double sizeMult; // HP in multiples of TDEE
  final int zone; // 0..5 within each depth
  final int depth; // 0 = first lap of the road
  final bool guardian; // last of its zone
  const EnemyDef({
    required this.index,
    required this.name,
    required this.flavor,
    required this.sizeMult,
    required this.zone,
    required this.depth,
    required this.guardian,
  });

  String get zoneName =>
      depth == 0 ? kZones[zone].name : '${kZones[zone].name} ($depth+)';
}

const List<double> _kSizeLadder = <double>[
  0.8, 0.85, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.7, 2.2
];

const List<List<String>> _kEnemyNames = <List<String>>[
  <String>[
    'Nibbler', 'Crumbsnatch', 'The Grazer', 'Saucling', 'Second Helping',
    'Snackling', 'The Lid-Lifter', 'Spoonwraith', 'Crustling',
    'The Fridge Goblin',
  ],
  <String>[
    'Chipmuncher', 'The Vending Sprite', 'Saltfang', 'Sweetooth',
    'The Drive-Thru Imp', 'Cheese Wisp', 'The Breakroom Ghoul',
    'Croissant Golem', 'Portion Ghost', 'The Doorbell Beast',
  ],
  <String>[
    'Grazehorn', 'The Sampler', 'Butterbeast', 'Refill Rat',
    'The Standing Eater', 'Dressing Djinn', 'Carbcap',
    'The Mindless Muncher', 'Plate Cleaner', 'Sir Seconds',
  ],
  <String>[
    'The Nightcap', 'Fridgelight Phantom', 'The 9PM Whisper', 'Couch Gremlin',
    'Streamfeeder', 'The Last Slice', 'Midnight Cerealist',
    'The Pantry Poltergeist', 'Sleepless Snacker', 'The Insomnomnom',
  ],
  <String>[
    'Heaping Horror', 'The Bottomless Basket', 'Gravy Elemental',
    'The Free Refill', 'Two-Plate Terror', 'The Garnish Ghast', 'Fryer Fiend',
    'The Dessert Cart', 'Stuffed Shell', 'The All-You-Can-Eat',
  ],
  <String>[
    'The Stall', 'Scale Sphinx', 'Water-Weight Wraith',
    'The Setpoint Sentinel', 'Metabolic Mimic', 'The Old Habit',
    'Backslide Basilisk', 'The Comfort Zone', 'Almost-There', 'The Plateau',
  ],
];

const List<List<String>> _kEnemyFlavor = <List<String>>[
  <String>[
    'Small, twitchy, too many fingers.',
    'Lives off what falls between meals.',
    'Never sits down. Always chewing.',
    'A drip of this, a drizzle of that.',
    'Round, contented, carries two spoons.',
    'Barely a threat. Barely.',
    'You heard the jar open too.',
    'Haunts the space between forks.',
    'The end of every loaf.',
    'Guards the cold light. Hates being seen.',
  ],
  <String>[
    'One is never one.',
    'Exact change, zero nutrition.',
    'Everything it touches needs a drink after.',
    'Speaks only in dessert.',
    'It knows your order by heart.',
    'Melts over everything it meets.',
    'Free food, no plate, no log.',
    'Laminated. Layered. Lethal.',
    'The food you didn\'t weigh. Translucent for a reason.',
    'It rings. You answer. Every time.',
  ],
  <String>[
    'Long horns, longer lunches.',
    'Just a taste. Of everything.',
    'Slow, rich, impossible to stop mid-slice.',
    'The glass is never empty. That\'s the problem.',
    'Eats over the sink like a raccoon in a shirt.',
    'Two hundred calories hiding on a salad.',
    'Wears its bread like armor.',
    'You weren\'t even hungry.',
    'Waste not, gain lots.',
    'A knight sworn to the second serving.',
  ],
  <String>[
    'Droopy-eyed. Holding a glass. Patient.',
    'Appears only in the glow of an open door.',
    'You know what it says.',
    'Lives under the blanket. Feeds during credits.',
    'Autoplay is its hunting call.',
    'It would be a shame to leave just one.',
    'Bowl, spoon, moonlight.',
    'Rattles the boxes so you remember they\'re there.',
    'If you\'re up anyway...',
    'The hunger that only exists after ten.',
  ],
  <String>[
    'Its plate has its own gravity.',
    'Somebody keeps refilling it. Nobody knows who.',
    'Pours itself over everything.',
    'The price of zero is never zero.',
    'Why carry one when you have two hands?',
    'It\'s just a garnish. It\'s just six garnishes.',
    'Everything it owns is golden brown.',
    'It rolls up right when you surrender.',
    'Filled past all reason.',
    'The banner said unlimited. It meant you.',
  ],
  <String>[
    'A wall with a face. It does not taunt. It does not move.',
    'Asks the same riddle every morning.',
    'Three pounds of nothing, gone by Thursday.',
    'It remembers the weight you always return to.',
    'Copies your effort, cancels your math.',
    'It knows the old route to the old you.',
    'One loose weekend and it grows a head.',
    'Warm, familiar, exactly your size.',
    'The last two pounds weigh the most.',
    'It has outlasted everyone. It plans to outlast you.',
  ],
];

/// The enemy at absolute road position [index]. The first 60 are the named
/// roster; past that the road keeps generating harder laps forever.
EnemyDef enemyAt(int index) {
  final int depth = index ~/ 60;
  final int slot = index % 60;
  final int zone = slot ~/ 10;
  final int pos = slot % 10;
  String name = _kEnemyNames[zone][pos];
  if (depth == 1) {
    name = 'Elder $name';
  } else if (depth >= 2) {
    name = 'Primal $name ${'★' * min(depth - 1, 3)}';
  }
  return EnemyDef(
    index: index,
    name: name,
    flavor: _kEnemyFlavor[zone][pos],
    sizeMult: _kSizeLadder[pos] * (1 + 0.1 * zone) * pow(1.5, depth).toDouble(),
    zone: zone,
    depth: depth,
    guardian: pos == 9,
  );
}

// ── weekend bosses (rotating cast) ──────────────────────────────────────

class BossDef {
  final String name;
  final String flavor;
  const BossDef(this.name, this.flavor);
}

const List<BossDef> kWeekendBosses = <BossDef>[
  BossDef('The Weekender', 'Shows up Friday night wearing your plans.'),
  BossDef('Brunch Behemoth', 'Bottomless is a threat, not a promise.'),
  BossDef('The Patio King', 'Every round on the patio is one of his.'),
  BossDef('Date Night Dragon', 'Hoards appetizers. Breathes dessert menus.'),
  BossDef('The Tailgater', 'Arrives three hours before kickoff. So does the food.'),
  BossDef('Cookout Colossus', 'One burger is a myth it invented.'),
  BossDef('The Open Bar', 'Nothing it pours has a label with numbers on it.'),
  BossDef('Pizza Night Prime', 'The box says 8 slices. It says otherwise.'),
  BossDef('The In-Laws', 'Refusing a plate is not an option here.'),
  BossDef('Buffet Baron', 'Taxes you one plate at a time.'),
  BossDef('The Long Weekend', 'Three days deep, no scale in sight.'),
  BossDef('Sunday Scaries', 'Eats your resolve for Monday.'),
];

// ── records ─────────────────────────────────────────────────────────────

class CombatEvent {
  final String date;
  final String kind; // hit|heal|over|silent|regen|run|cheat|kill|ko|
  //                    boss_win|boss_loss|boss_none|spawn
  final String text;
  final double amount; // damage dealt (+) / enemy healed or player hit
  const CombatEvent(this.date, this.kind, this.text, [this.amount = 0]);
}

class KillRecord {
  final EnemyDef enemy;
  final String spawnDate;
  final String killDate;
  final int fightDays;
  final double maxHp;
  const KillRecord(
      this.enemy, this.spawnDate, this.killDate, this.fightDays, this.maxHp);
}

class BossRecord {
  final String saturday;
  final BossDef boss;
  final String result; // 'won' | 'lost' | 'no_mark' | 'pending'
  final String? markDate;
  final double? markWeight;
  final double? verdictWeight; // Monday morning's number
  final double threshold; // lb of gain allowed over the window
  final double avgGain; // the benchmark/day it was computed from
  const BossRecord({
    required this.saturday,
    required this.boss,
    required this.result,
    required this.threshold,
    required this.avgGain,
    this.markDate,
    this.markWeight,
    this.verdictWeight,
  });

  double? get gain => markWeight == null || verdictWeight == null
      ? null
      : verdictWeight! - markWeight!;
}

/// One sampled day of hero stats, for the 90-day sparklines.
class StatSample {
  final String date;
  final double strength; // 0..1
  final double vitality; // 0..1 (of the 80..120 band)
  final double endurance; // 0..1
  final double discipline; // 0..1
  const StatSample(this.date, this.strength, this.vitality, this.endurance,
      this.discipline);
}

// ── the computed state ──────────────────────────────────────────────────

class CampaignState {
  // today's fight
  final EnemyDef enemy;
  final double enemyHp;
  final double enemyMaxHp;
  final String enemySpawnDate;
  final double playerHp;
  final double playerMaxHp;
  final double? pendingDamage; // today's live hit (null = nothing logged yet)
  final bool weekendMode; // Sat/Sun (or Mon with an unresolved boss)

  // the active weekend boss, when one is on screen
  final BossRecord? activeBoss;

  // hero
  final double strength, vitality, endurance, discipline; // 0..1
  final double strengthMult;
  final double regenPerDay;
  final List<StatSample> statHistory; // oldest → newest, ≤90 days
  final int xp; // campaign XP (kills + boss wins) → shared level economy

  // the final boss
  final double fatBossHp; // calories between you and target BF%
  final double fatBossMax;

  // records
  final List<KillRecord> kills;
  final List<BossRecord> bossLedger; // oldest → newest
  final List<CombatEvent> log; // oldest → newest (tail)
  final int koCount;
  final double totalDamage;
  final double totalHealed; // enemy healing you paid for
  final int settledWeekdays;
  final int hitDays;
  final int currentHitStreak;
  final int bestHitStreak;
  final double biggestHit;
  final String? biggestHitDate;
  final int longestFightDays;
  final int fastestKillDays; // 0 = none yet
  final Map<int, double> avgDamageByWeekday; // DateTime.monday..sunday
  final Map<String, double> damageByDate; // settled weekdays only
  final Map<int, double> caloriesByHour; // 0..23, last 60 days
  final double avgDamagePerDay; // over settled weekdays with known intake
  final double tdee;
  final int tdeeValidDays;
  final double unloggedGainPerDay; // the boss benchmark right now

  const CampaignState({
    required this.enemy,
    required this.enemyHp,
    required this.enemyMaxHp,
    required this.enemySpawnDate,
    required this.playerHp,
    required this.playerMaxHp,
    required this.pendingDamage,
    required this.weekendMode,
    required this.activeBoss,
    required this.strength,
    required this.vitality,
    required this.endurance,
    required this.discipline,
    required this.strengthMult,
    required this.regenPerDay,
    required this.statHistory,
    required this.xp,
    required this.fatBossHp,
    required this.fatBossMax,
    required this.kills,
    required this.bossLedger,
    required this.log,
    required this.koCount,
    required this.totalDamage,
    required this.totalHealed,
    required this.settledWeekdays,
    required this.hitDays,
    required this.currentHitStreak,
    required this.bestHitStreak,
    required this.biggestHit,
    required this.biggestHitDate,
    required this.longestFightDays,
    required this.fastestKillDays,
    required this.avgDamageByWeekday,
    required this.damageByDate,
    required this.caloriesByHour,
    required this.avgDamagePerDay,
    required this.tdee,
    required this.tdeeValidDays,
    required this.unloggedGainPerDay,
  });

  double get hitRate => settledWeekdays == 0 ? 0 : hitDays / settledWeekdays;
  int get bossWins =>
      bossLedger.where((BossRecord b) => b.result == 'won').length;
  int get bossLosses =>
      bossLedger.where((BossRecord b) => b.result == 'lost').length;
}

// ── the engine ──────────────────────────────────────────────────────────

class CampaignEngine {
  static CampaignState compute({
    required UserCalibration cal,
    required List<DailyLog> logs,
    required List<FoodEntry> foods,
    required Set<String> fasted,
    List<RunRecord> runs = const <RunRecord>[],
    List<SleepEntry> sleep = const <SleepEntry>[],
    required String startDate,
    DateTime? asOf,
  }) {
    final DateTime now = asOf ?? DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime start = DateTime.tryParse(startDate) ?? today;

    // ── prebuilt lookups ─────────────────────────────────────────────
    final List<DailyLog> sorted = List<DailyLog>.of(logs)
      ..sort((DailyLog a, DailyLog b) => a.date.compareTo(b.date));
    final Map<String, double> calsByDate = FoodMath.caloriesByDate(foods);
    final Map<String, int> intake =
        MathEngine.knownIntakeByDate(sorted, calsByDate, fasted);
    final Map<String, double> weightByDate = <String, double>{
      for (final DailyLog l in sorted) l.date: l.weight
    };
    final Map<String, double> proteinByDate = <String, double>{};
    for (final FoodEntry f in foods) {
      proteinByDate[f.date] = (proteinByDate[f.date] ?? 0) + f.protein;
    }
    final Map<String, double> sleepByDate = <String, double>{};
    for (final SleepEntry s in sleep) {
      sleepByDate[s.date] = max(sleepByDate[s.date] ?? 0, s.hours);
    }
    final Map<String, double> runCalByDate = <String, double>{};
    final Map<String, double> runKmByDate = <String, double>{};
    for (final RunRecord r in runs) {
      final double kcal = r.calories ??
          0.4 * (_weightOn(sorted, r.date) ?? cal.startWeight) * r.distanceKm;
      runCalByDate[r.date] = (runCalByDate[r.date] ?? 0) + kcal;
      runKmByDate[r.date] = (runKmByDate[r.date] ?? 0) + r.distanceKm;
    }

    double tdeeUpTo(String date) {
      final List<DailyLog> upTo =
          sorted.where((DailyLog l) => l.date.compareTo(date) <= 0).toList();
      if (upTo.isEmpty) {
        return kDefaultTdee;
      }
      final double t = MathEngine.tdeeInfo(upTo, cal.activityMult,
              caloriesByDate: calsByDate,
              fastedDates: fasted,
              resetDate: cal.tdeeResetDate)
          .tdee;
      return t > 0 ? t : kDefaultTdee;
    }

    // ── hero stat curves (all deterministic per date) ────────────────
    double strengthPct(DateTime d) {
      double got = 0;
      int days = 0;
      for (int i = 0; i < 7; i++) {
        final String key = formatDate(d.subtract(Duration(days: i)));
        final double? p = proteinByDate[key];
        if (p != null && p > 0) {
          got += p;
          days++;
        }
      }
      if (days == 0) {
        return 0;
      }
      final double lbm = _lbmOn(sorted, formatDate(d)) ?? cal.startLbm;
      final double target = cal.proteinTarget ?? lbm;
      return target <= 0 ? 0 : ((got / days) / target).clamp(0.0, 1.0);
    }

    double vitalityPct(DateTime d) {
      double got = 0;
      int nights = 0;
      for (int i = 0; i < 7; i++) {
        final double? h = sleepByDate[formatDate(d.subtract(Duration(days: i)))];
        if (h != null && h > 0) {
          got += h;
          nights++;
        }
      }
      if (nights == 0) {
        return 0.5; // no sleep data → the neutral 100 HP
      }
      return ((got / nights - 5.5) / 2.5).clamp(0.0, 1.0); // 5.5h..8h
    }

    double endurancePct(DateTime d) {
      double km = 0;
      for (int i = 0; i < 30; i++) {
        km += runKmByDate[formatDate(d.subtract(Duration(days: i)))] ?? 0;
      }
      return (km / 30.0).clamp(0.0, 1.0); // 30 km/month = full bar
    }

    double disciplinePct(DateTime d) {
      int known = 0;
      for (int i = 0; i < 30; i++) {
        if (intake.containsKey(formatDate(d.subtract(Duration(days: i))))) {
          known++;
        }
      }
      return known / 30.0;
    }

    double maxHpOn(DateTime d) => 80 + 40 * vitalityPct(d);
    double regenOn(DateTime d) => 6 + 6 * disciplinePct(d);
    double strengthMultOn(DateTime d) => 1 + 0.15 * strengthPct(d);

    double runBaseline(DateTime d) {
      double kcal = 0;
      for (int i = 1; i <= 30; i++) {
        kcal += runCalByDate[formatDate(d.subtract(Duration(days: i)))] ?? 0;
      }
      return kcal / 30.0;
    }

    // ── mutable battle state ─────────────────────────────────────────
    int enemyIdx = 0;
    EnemyDef enemy = enemyAt(0);
    double enemyMaxHp = tdeeUpTo(startDate) * enemy.sizeMult;
    double enemyHp = enemyMaxHp;
    String spawnDate = startDate;
    double playerHp = maxHpOn(start);
    int koCount = 0;
    int xp = 0;
    final List<KillRecord> kills = <KillRecord>[];
    final List<BossRecord> ledger = <BossRecord>[];
    final List<CombatEvent> events = <CombatEvent>[];
    final List<StatSample> statHistory = <StatSample>[];
    double totalDamage = 0, totalHealed = 0, biggestHit = 0;
    String? biggestHitDate;
    int settledWeekdays = 0, hitDays = 0, curStreak = 0, bestStreak = 0;
    int longestFight = 0, fastestKill = 0;
    final Map<int, double> wdSum = <int, double>{};
    final Map<int, int> wdCount = <int, int>{};
    final Map<String, double> dmgByDate = <String, double>{};
    double knownDamageSum = 0;
    int knownDamageDays = 0;
    String cheatMutedUntil = '';
    // The unresolved weekend fight, keyed by its Saturday.
    String? openBossSaturday;
    String? openBossMarkDate;
    double? openBossMarkWeight;
    double openBossThreshold = 0;
    double openBossAvg = kDefaultUnloggedGain;

    void logEvent(String date, String kind, String text, [double amt = 0]) {
      events.add(CombatEvent(date, kind, text, amt));
    }

    void spawnNext(String date) {
      enemyIdx++;
      enemy = enemyAt(enemyIdx);
      enemyMaxHp = tdeeUpTo(date) * enemy.sizeMult;
      enemyHp = enemyMaxHp;
      spawnDate = date;
      logEvent(date, 'spawn',
          '${enemy.name} blocks the road. ${enemy.flavor}');
    }

    void onKill(String date) {
      final int days =
          DateTime.parse(date).difference(DateTime.parse(spawnDate)).inDays + 1;
      kills.add(KillRecord(enemy, spawnDate, date, days, enemyMaxHp));
      final int gained = (enemy.sizeMult * 100).round().clamp(50, 500);
      xp += gained;
      longestFight = max(longestFight, days);
      fastestKill = fastestKill == 0 ? days : min(fastestKill, days);
      logEvent(date, 'kill',
          '${enemy.name} falls after $days day${days == 1 ? '' : 's'}. '
          '+$gained XP. You are fully healed.');
      spawnNext(date);
    }

    void hitEnemy(String date, double dmg, String kind, String text) {
      enemyHp -= dmg;
      totalDamage += dmg;
      if (dmg > biggestHit) {
        biggestHit = dmg;
        biggestHitDate = date;
      }
      logEvent(date, kind, text, dmg);
      if (enemyHp <= 0) {
        playerHp = maxHpOn(DateTime.parse(date));
        onKill(date);
      }
    }

    void hurtPlayer(String date, double dmg, String kind, String text) {
      playerHp -= dmg;
      logEvent(date, kind, text, -dmg);
      if (playerHp <= 0) {
        koCount++;
        enemyHp = enemyMaxHp;
        playerHp = maxHpOn(DateTime.parse(date));
        logEvent(date, 'ko',
            'K.O. — ${enemy.name} recovers to full while you regroup.');
      }
    }

    /// Average lb gained per unlogged day, learned from every weigh-in pair
    /// whose in-between days are ALL unknown intake (weekends and silent
    /// weekdays alike). This IS the boss ratchet: every weekend you win
    /// pulls the average down, so the next boss demands more.
    double unloggedGain(String before) {
      double lb = 0;
      int days = 0;
      for (int i = 0; i + 1 < sorted.length; i++) {
        if (sorted[i + 1].date.compareTo(before) > 0) {
          break;
        }
        final DateTime a = DateTime.parse(sorted[i].date);
        final DateTime b = DateTime.parse(sorted[i + 1].date);
        final int gap = b.difference(a).inDays;
        if (gap < 1 || gap > 7) {
          continue;
        }
        bool allUnknown = true;
        for (int k = 0; k < gap; k++) {
          if (intake.containsKey(formatDate(a.add(Duration(days: k))))) {
            allUnknown = false;
            break;
          }
        }
        if (!allUnknown) {
          continue;
        }
        lb += sorted[i + 1].weight - sorted[i].weight;
        days += gap;
      }
      return days >= 4 ? lb / days : kDefaultUnloggedGain;
    }

    /// Saturday spawn: find the mark (Sat, else Fri, else Thu weigh-in).
    void trySpawnBoss(DateTime sat, {required bool record}) {
      final String satKey = formatDate(sat);
      String? markDate;
      for (int back = 0; back <= 2; back++) {
        final String k = formatDate(sat.subtract(Duration(days: back)));
        if (weightByDate.containsKey(k)) {
          markDate = k;
          break;
        }
      }
      final int week =
          sat.difference(DateTime(2026, 1, 3)).inDays ~/ 7; // any fixed Sat
      final BossDef boss = kWeekendBosses[week % kWeekendBosses.length];
      if (markDate == null) {
        if (record) {
          ledger.add(BossRecord(
              saturday: satKey,
              boss: boss,
              result: 'no_mark',
              threshold: 0,
              avgGain: unloggedGain(satKey)));
          logEvent(satKey, 'boss_none',
              'No weigh-in since Thursday — ${boss.name} passes you by.');
        }
        return;
      }
      final double avg = unloggedGain(satKey);
      final DateTime monday = sat.add(const Duration(days: 2));
      final int span = monday.difference(DateTime.parse(markDate)).inDays;
      openBossSaturday = satKey;
      openBossMarkDate = markDate;
      openBossMarkWeight = weightByDate[markDate];
      openBossAvg = avg;
      openBossThreshold =
          double.parse((max(avg, 0) * span).toStringAsFixed(2));
      logEvent(satKey, 'spawn',
          '${boss.name} appears. Gain less than '
          '${openBossThreshold.toStringAsFixed(1)} lb by Monday morning.');
    }

    /// Monday-morning verdict. [monKey] must be the Monday two days after
    /// the open boss's Saturday.
    void resolveBoss(String monKey) {
      final DateTime sat = DateTime.parse(openBossSaturday!);
      final int week = sat.difference(DateTime(2026, 1, 3)).inDays ~/ 7;
      final BossDef boss = kWeekendBosses[week % kWeekendBosses.length];
      final double? monWeight = weightByDate[monKey];
      if (monWeight == null) {
        ledger.add(BossRecord(
            saturday: openBossSaturday!,
            boss: boss,
            result: 'lost',
            markDate: openBossMarkDate,
            markWeight: openBossMarkWeight,
            threshold: openBossThreshold,
            avgGain: openBossAvg));
        logEvent(monKey, 'boss_loss',
            'No Monday weigh-in. ${boss.name} wins by forfeit.');
      } else {
        final double gain = monWeight - openBossMarkWeight!;
        final bool won = gain <= openBossThreshold;
        ledger.add(BossRecord(
            saturday: openBossSaturday!,
            boss: boss,
            result: won ? 'won' : 'lost',
            markDate: openBossMarkDate,
            markWeight: openBossMarkWeight,
            verdictWeight: monWeight,
            threshold: openBossThreshold,
            avgGain: openBossAvg));
        if (won) {
          xp += kBossWinXp;
          playerHp = maxHpOn(DateTime.parse(monKey));
          final double freeHit =
              knownDamageDays > 0 ? knownDamageSum / knownDamageDays : 400;
          logEvent(monKey, 'boss_win',
              '${boss.name} defeated (${gain >= 0 ? '+' : ''}'
              '${gain.toStringAsFixed(1)} lb vs '
              '+${openBossThreshold.toStringAsFixed(1)} allowed). '
              '+$kBossWinXp XP. Full heal.');
          if (freeHit > 0) {
            hitEnemy(monKey, freeHit, 'hit',
                'Momentum from the weekend — free hit on ${enemy.name}.');
          }
        } else {
          logEvent(monKey, 'boss_loss',
              '${boss.name} wins (${gain >= 0 ? '+' : ''}'
              '${gain.toStringAsFixed(1)} lb vs '
              '+${openBossThreshold.toStringAsFixed(1)} allowed).');
        }
      }
      openBossSaturday = null;
      openBossMarkDate = null;
      openBossMarkWeight = null;
    }

    /// Trailing-window comparison of what the log implies vs what the scale
    /// says. Never fires on one day — water alone would trip it constantly.
    bool cheatCheck(String date) {
      if (cheatMutedUntil.isNotEmpty &&
          date.compareTo(cheatMutedUntil) < 0) {
        return false;
      }
      final DateTime d = DateTime.parse(date);
      int known = 0;
      double expectedDrop = 0;
      final double tdeeD = tdeeUpTo(date);
      for (int i = 0; i < kCheatWindow; i++) {
        final String k = formatDate(d.subtract(Duration(days: i)));
        final int? cal = intake[k];
        if (cal != null) {
          known++;
          expectedDrop += (tdeeD - cal) / 3500.0;
        }
      }
      if (known < 5 || expectedDrop <= 0) {
        return false;
      }
      final double? startW = _windowAvg(weightByDate, d, 9, 6);
      final double? endW = _windowAvg(weightByDate, d, 2, 0);
      if (startW == null || endW == null) {
        return false;
      }
      final double actualDrop = startW - endW;
      if (actualDrop < expectedDrop - kCheatSlackLb) {
        cheatMutedUntil =
            formatDate(d.add(const Duration(days: kCheatWindow)));
        return true;
      }
      return false;
    }

    // ── the settled loop: every full day from start to yesterday ─────
    final DateTime statWindow = today.subtract(const Duration(days: 90));
    for (DateTime d = start;
        d.isBefore(today);
        d = d.add(const Duration(days: 1))) {
      final String key = formatDate(d);
      final int wd = d.weekday;
      final double maxHp = maxHpOn(d);
      playerHp = min(playerHp, maxHp);

      if (!d.isBefore(statWindow)) {
        statHistory.add(StatSample(key, strengthPct(d), vitalityPct(d),
            endurancePct(d), disciplinePct(d)));
      }

      // Monday morning: the boss verdict comes before anything else.
      if (wd == DateTime.monday && openBossSaturday != null) {
        resolveBoss(key);
      }

      if (wd == DateTime.saturday) {
        trySpawnBoss(d, record: true);
        continue; // weekend: enemy frozen, no logging rules
      }
      if (wd == DateTime.sunday) {
        continue;
      }

      settledWeekdays++;
      final int? cal = intake[key];
      final double tdeeD = tdeeUpTo(key);
      double dayDamage = 0;

      if (cal == null) {
        hurtPlayer(key, kUnloggedHit, 'silent',
            'Silent day — no log, no swing. −${kUnloggedHit.round()} HP.');
      } else {
        knownDamageDays++;
        final double raw = tdeeD - cal;
        if (raw > 0) {
          final double dmg =
              min(raw, tdeeD - kIntakeFloor) * strengthMultOn(d);
          knownDamageSum += dmg;
          dayDamage += dmg;
          hitEnemy(key, dmg, 'hit',
              'You hit ${enemy.name} for ${dmg.round()}.');
          final double regen = regenOn(d);
          playerHp = min(maxHp, playerHp + regen);
          logEvent(key, 'regen', 'Clean day. +${regen.round()} HP.');
        } else if (raw < 0) {
          final double surplus = -raw;
          final double healed = min(surplus, enemyMaxHp - enemyHp);
          enemyHp += healed;
          totalHealed += surplus;
          logEvent(key, 'heal',
              '${enemy.name} heals ${surplus.round()} — you went over.',
              -surplus);
          final double over = 10 + 15 * (surplus / 500.0).clamp(0.0, 1.0);
          hurtPlayer(key, over, 'over',
              'Over maintenance. −${over.round()} HP.');
        }
      }

      // A run above your typical activity is a real extra burn.
      final double runCal = runCalByDate[key] ?? 0;
      if (runCal > 0) {
        final double extra = runCal - runBaseline(d);
        if (extra >= kRunAttackMin) {
          dayDamage += extra;
          hitEnemy(key, extra, 'run',
              'RUN ATTACK — ${extra.round()} beyond your usual mileage.');
        }
      }

      if (cal != null && cheatCheck(key)) {
        hurtPlayer(key, kCheatHit, 'cheat',
            'The scale disagrees with the log this week. '
            '${enemy.name} lands a sucker punch. −${kCheatHit.round()} HP.');
      }

      if (dayDamage > 0) {
        hitDays++;
        curStreak++;
        bestStreak = max(bestStreak, curStreak);
      } else {
        curStreak = 0;
      }
      wdSum[wd] = (wdSum[wd] ?? 0) + dayDamage;
      wdCount[wd] = (wdCount[wd] ?? 0) + 1;
      dmgByDate[key] = dayDamage;
    }

    // ── today: pending, not settled ──────────────────────────────────
    final String todayKey = formatDate(today);
    final int todayWd = today.weekday;
    final double tdeeNow = tdeeUpTo(todayKey);
    playerHp = min(playerHp, maxHpOn(today));

    // Monday morning with a live boss: resolve as soon as the weigh-in
    // exists (the settled loop will reach the same verdict tomorrow).
    if (todayWd == DateTime.monday && openBossSaturday != null) {
      if (weightByDate.containsKey(todayKey)) {
        resolveBoss(todayKey);
      }
    } else if (todayWd == DateTime.saturday && openBossSaturday == null) {
      trySpawnBoss(today, record: false);
    }

    BossRecord? activeBoss;
    if (openBossSaturday != null) {
      final DateTime sat = DateTime.parse(openBossSaturday!);
      final int week = sat.difference(DateTime(2026, 1, 3)).inDays ~/ 7;
      activeBoss = BossRecord(
          saturday: openBossSaturday!,
          boss: kWeekendBosses[week % kWeekendBosses.length],
          result: 'pending',
          markDate: openBossMarkDate,
          markWeight: openBossMarkWeight,
          threshold: openBossThreshold,
          avgGain: openBossAvg);
    } else if (todayWd == DateTime.saturday || todayWd == DateTime.sunday) {
      // Weekend with no mark: the boss card explains itself.
      final DateTime sat = todayWd == DateTime.saturday
          ? today
          : today.subtract(const Duration(days: 1));
      final int week = sat.difference(DateTime(2026, 1, 3)).inDays ~/ 7;
      activeBoss = BossRecord(
          saturday: formatDate(sat),
          boss: kWeekendBosses[week % kWeekendBosses.length],
          result: 'no_mark',
          threshold: 0,
          avgGain: unloggedGain(formatDate(sat)));
    }

    final bool weekendMode = todayWd == DateTime.saturday ||
        todayWd == DateTime.sunday ||
        (todayWd == DateTime.monday && openBossSaturday != null);

    double? pending;
    if (!weekendMode) {
      final double? soFar = calsByDate[todayKey];
      if (soFar != null && soFar > 0) {
        pending = tdeeNow - soFar;
        if (pending > 0) {
          pending = min(pending, tdeeNow - kIntakeFloor) *
              strengthMultOn(today);
        }
      } else if (fasted.contains(todayKey)) {
        pending = (tdeeNow - kIntakeFloor) * strengthMultOn(today);
      }
    }

    // ── the final boss ───────────────────────────────────────────────
    double fatBossHp = 0, fatBossMax = 0;
    if (sorted.isNotEmpty) {
      final int n = sorted.length;
      final List<DailyLog> tail = sorted.sublist(max(0, n - 7));
      final double lbmAvg =
          tail.fold<double>(0, (double s, DailyLog l) => s + l.lbm) /
              tail.length;
      final double fatAvg =
          tail.fold<double>(0, (double s, DailyLog l) => s + l.fatMass) /
              tail.length;
      final double targetFat = lbmAvg * cal.targetBf / (1 - cal.targetBf);
      fatBossHp = max(0, (fatAvg - targetFat) * 3500);
      final double startTargetFat =
          cal.startLbm * cal.targetBf / (1 - cal.targetBf);
      fatBossMax =
          max(fatBossHp, (cal.startFatMass - startTargetFat) * 3500);
    }

    // ── calories by hour (last 60 days) ──────────────────────────────
    final Map<int, double> byHour = <int, double>{};
    final String hourFloor =
        formatDate(today.subtract(const Duration(days: 60)));
    for (final FoodEntry f in foods) {
      if (f.date.compareTo(hourFloor) < 0 || f.time.length < 2) {
        continue;
      }
      final int? h = int.tryParse(f.time.split(':').first);
      if (h == null || h < 0 || h > 23) {
        continue;
      }
      byHour[h] = (byHour[h] ?? 0) + f.calories;
    }

    final Map<int, double> wdAvg = <int, double>{
      for (final int wd in wdSum.keys)
        wd: wdSum[wd]! / max(1, wdCount[wd] ?? 1)
    };

    statHistory.add(StatSample(todayKey, strengthPct(today),
        vitalityPct(today), endurancePct(today), disciplinePct(today)));

    return CampaignState(
      enemy: enemy,
      enemyHp: enemyHp.clamp(0, enemyMaxHp),
      enemyMaxHp: enemyMaxHp,
      enemySpawnDate: spawnDate,
      playerHp: playerHp.clamp(0, maxHpOn(today)),
      playerMaxHp: maxHpOn(today),
      pendingDamage: pending,
      weekendMode: weekendMode,
      activeBoss: activeBoss,
      strength: strengthPct(today),
      vitality: vitalityPct(today),
      endurance: endurancePct(today),
      discipline: disciplinePct(today),
      strengthMult: strengthMultOn(today),
      regenPerDay: regenOn(today),
      statHistory: statHistory,
      xp: xp,
      fatBossHp: fatBossHp,
      fatBossMax: fatBossMax,
      kills: kills,
      bossLedger: ledger,
      log: events.length > 60 ? events.sublist(events.length - 60) : events,
      koCount: koCount,
      totalDamage: totalDamage,
      totalHealed: totalHealed,
      settledWeekdays: settledWeekdays,
      hitDays: hitDays,
      currentHitStreak: curStreak,
      bestHitStreak: bestStreak,
      biggestHit: biggestHit,
      biggestHitDate: biggestHitDate,
      longestFightDays: longestFight,
      fastestKillDays: fastestKill,
      avgDamageByWeekday: wdAvg,
      damageByDate: dmgByDate,
      caloriesByHour: byHour,
      avgDamagePerDay:
          knownDamageDays == 0 ? 0 : knownDamageSum / knownDamageDays,
      tdee: tdeeNow,
      tdeeValidDays: sorted.isEmpty
          ? 0
          : MathEngine.tdeeInfo(sorted, cal.activityMult,
                  caloriesByDate: calsByDate,
                  fastedDates: fasted,
                  resetDate: cal.tdeeResetDate)
              .validDays,
      unloggedGainPerDay: unloggedGain(todayKey),
    );
  }

  static double? _weightOn(List<DailyLog> sorted, String date) {
    double? w;
    for (final DailyLog l in sorted) {
      if (l.date.compareTo(date) > 0) {
        break;
      }
      w = l.weight;
    }
    return w;
  }

  static double? _lbmOn(List<DailyLog> sorted, String date) {
    double? v;
    for (final DailyLog l in sorted) {
      if (l.date.compareTo(date) > 0) {
        break;
      }
      v = l.lbm;
    }
    return v;
  }

  /// Average of weigh-ins in the window [d−fromBack, d−toBack] (inclusive).
  static double? _windowAvg(
      Map<String, double> weightByDate, DateTime d, int fromBack, int toBack) {
    double sum = 0;
    int n = 0;
    for (int i = toBack; i <= fromBack; i++) {
      final double? w = weightByDate[formatDate(d.subtract(Duration(days: i)))];
      if (w != null) {
        sum += w;
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// CHAD — the rival. Loses exactly 1 lb a week, every week, forever.
// Cumulative from the race anchor; only a recalibration re-anchors him.
// ═══════════════════════════════════════════════════════════════════════

class RivalPoint {
  final String date;
  final double you; // trend weight
  final double chad;
  const RivalPoint(this.date, this.you, this.chad);
}

class RivalState {
  final bool hasData;
  final String anchorDate;
  final double anchorWeight;
  final double chadWeight;
  final double yourTrend;
  final double gap; // + : Chad is lighter (ahead). − : you passed him.
  final int mood; // 0 relaxed · 1 smug · 2 sweating · 3 annoyed
  final String line;
  final List<RivalPoint> series; // oldest → newest
  const RivalState({
    required this.hasData,
    required this.anchorDate,
    required this.anchorWeight,
    required this.chadWeight,
    required this.yourTrend,
    required this.gap,
    required this.mood,
    required this.line,
    required this.series,
  });

  static const RivalState empty = RivalState(
      hasData: false,
      anchorDate: '',
      anchorWeight: 0,
      chadWeight: 0,
      yourTrend: 0,
      gap: 0,
      mood: 1,
      line: 'Whenever you\'re ready. No rush. I\'ll wait at the start line.',
      series: <RivalPoint>[]);
}

const List<List<String>> _kChadLines = <List<String>>[
  <String>[
    // 0 relaxed — comfortably ahead
    'Another pound. Like clockwork.',
    'I\'d say catch up, but I don\'t believe in miracles.',
    'This isn\'t even hard. For me, anyway.',
    'You know where I\'ll be. Further ahead.',
    'I put in my week. Did you?',
    'The view from down here is great, by the way.',
  ],
  <String>[
    // 1 smug — ahead, but within reach
    'Oh — you\'re still here.',
    'A pound a week. Try it sometime.',
    'Cute streak. I have a better one.',
    'You had a good day. I had a good week.',
    'I don\'t skip weekends. Just saying.',
    'Keep going. It almost worked.',
  ],
  <String>[
    // 2 sweating — you're closing in
    'That\'s... closer than I\'d like.',
    'Okay. Who told you about consistency?',
    'I\'m not worried. I\'m pacing. That\'s different.',
    'You logged all week? That\'s against the rules.',
    'Stay back there. It\'s roomy back there.',
    'One pound. Every week. Me. Remember that.',
  ],
  <String>[
    // 3 annoyed — you passed him
    'This is temporary.',
    'I let you have that one.',
    'Enjoy it. I don\'t have off-weeks, remember.',
    'Fine. FINE.',
    'I\'m recalculating my strategy. It\'s still "one pound a week".',
    'Nobody likes a show-off.',
  ],
];

class RivalEngine {
  /// [campaignStart] is the stored race-start date; a recalibration
  /// ([resetDate]) after it re-anchors the race there.
  static RivalState compute(List<DailyLog> logs,
      {required String campaignStart, String? resetDate, DateTime? asOf}) {
    final DateTime now = asOf ?? DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    String anchor = campaignStart;
    if (resetDate != null &&
        resetDate.isNotEmpty &&
        resetDate.compareTo(anchor) > 0) {
      anchor = resetDate;
    }
    final List<DailyLog> sorted = List<DailyLog>.of(logs)
      ..sort((DailyLog a, DailyLog b) => a.date.compareTo(b.date));
    if (sorted.isEmpty || anchor.isEmpty) {
      return RivalState.empty;
    }

    // Anchor weight: your trend where the race began — the average of the
    // week of weigh-ins up to the anchor, else the first one after it.
    final DateTime anchorDay = DateTime.tryParse(anchor) ?? today;
    double sum = 0;
    int n = 0;
    for (final DailyLog l in sorted) {
      final DateTime d = DateTime.parse(l.date);
      if (!d.isAfter(anchorDay) &&
          d.isAfter(anchorDay.subtract(const Duration(days: 7)))) {
        sum += l.weight;
        n++;
      }
    }
    double anchorWeight;
    if (n > 0) {
      anchorWeight = sum / n;
    } else {
      final Iterable<DailyLog> after =
          sorted.where((DailyLog l) => l.date.compareTo(anchor) >= 0);
      if (after.isEmpty) {
        return RivalState.empty;
      }
      anchorWeight = after.first.weight;
    }

    double trendAt(DateTime d) {
      final List<double> w = <double>[];
      for (int i = sorted.length - 1; i >= 0 && w.length < 7; i--) {
        if (DateTime.parse(sorted[i].date).isAfter(d)) {
          continue;
        }
        w.add(sorted[i].weight);
      }
      if (w.isEmpty) {
        return anchorWeight;
      }
      return w.reduce((double a, double b) => a + b) / w.length;
    }

    double chadAt(DateTime d) =>
        anchorWeight - d.difference(anchorDay).inDays / 7.0;

    final double yourTrend = trendAt(today);
    final double chadNow = chadAt(today);
    final double gap = yourTrend - chadNow;
    final int mood = gap <= 0
        ? 3
        : gap < 0.75
            ? 2
            : gap <= 3
                ? 1
                : 0;
    final List<String> lines = _kChadLines[mood];
    final int dayOrdinal = today.difference(DateTime(2026, 1, 1)).inDays;
    final String line = lines[dayOrdinal.abs() % lines.length];

    final List<RivalPoint> series = <RivalPoint>[];
    final DateTime from = today.subtract(const Duration(days: 59));
    final DateTime lo = from.isBefore(anchorDay) ? anchorDay : from;
    for (DateTime d = lo;
        !d.isAfter(today);
        d = d.add(const Duration(days: 1))) {
      series.add(RivalPoint(formatDate(d), trendAt(d), chadAt(d)));
    }

    return RivalState(
        hasData: true,
        anchorDate: anchor,
        anchorWeight: anchorWeight,
        chadWeight: chadNow,
        yourTrend: yourTrend,
        gap: gap,
        mood: mood,
        line: line,
        series: series);
  }
}
