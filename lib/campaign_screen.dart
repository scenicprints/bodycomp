import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'campaign.dart';
import 'creatures.dart';
import 'food.dart';
import 'goals.dart';
import 'main.dart';
import 'sleep.dart';
import 'trainer.dart';
import 'unlocks.dart';

// ═══════════════════════════════════════════════════════════════════════
// CAMPAIGN TAB — where the game lives.
// Fat-boss strip on top, then FIGHT · HERO · BESTIARY · RECORDS.
// ═══════════════════════════════════════════════════════════════════════

class CampaignScreen extends StatefulWidget {
  final bool active; // this tab is fronted — safe to fire celebrations
  final Color accent;
  final UserCalibration cal;
  final List<DailyLog> logs;
  final List<FoodEntry> foods;
  final List<String> fasted;
  final List<RunRecord> runs;
  final List<SleepEntry> sleep;
  final TrainerState trainer;
  final List<ChallengeRun> challenges;
  final Prestige prestige;
  final String campaignStart;

  const CampaignScreen({
    super.key,
    this.active = false,
    required this.accent,
    required this.cal,
    required this.logs,
    required this.foods,
    required this.fasted,
    required this.runs,
    required this.sleep,
    required this.trainer,
    required this.challenges,
    required this.prestige,
    required this.campaignStart,
  });

  @override
  State<CampaignScreen> createState() => _CampaignScreenState();
}

class _CampaignScreenState extends State<CampaignScreen> {
  int _page = 0;
  // Rises whenever today's pending hit visibly grows — the portrait flinches.
  double _lastPending = 0;
  int _flinchTick = 0;
  bool _celebrating = false;

  /// Fire a win popup for any kill/boss-win that has not been celebrated
  /// yet — only while this tab is fronted (IndexedStack builds every tab,
  /// so an ungated dialog would pop over the Dashboard).
  void _maybeCelebrate(CampaignState c) {
    if (!widget.active || _celebrating || !mounted) {
      return;
    }
    final int total = c.kills.length + c.bossWins;
    final String stored = AppStorage.getPref('campaignCelebrated', '');
    if (stored.isEmpty) {
      // First run with history: baseline silently, never replay the past.
      AppStorage.savePref('campaignCelebrated', '$total');
      return;
    }
    final int seen = int.tryParse(stored) ?? 0;
    if (total <= seen) {
      return;
    }
    AppStorage.savePref('campaignCelebrated', '$total');
    // Celebrate the most recent event only.
    final KillRecord? lastKill = c.kills.isNotEmpty ? c.kills.last : null;
    BossRecord? lastBossWin;
    for (final BossRecord b in c.bossLedger.reversed) {
      if (b.result == 'won') {
        lastBossWin = b;
        break;
      }
    }
    final bool bossNewer = lastBossWin != null &&
        (lastKill == null ||
            lastBossWin.saturday.compareTo(lastKill.killDate) > 0);
    _celebrating = true;
    showDialog<void>(
      context: context,
      builder: (_) => bossNewer
          ? _WinPop(
              title: 'BOSS DOWN',
              name: lastBossWin!.boss.name,
              sub: lastBossWin.gain == null
                  ? 'the weekend held'
                  : '${lastBossWin.gain! >= 0 ? '+' : ''}'
                      '${lastBossWin.gain!.toStringAsFixed(1)} lb vs '
                      '+${lastBossWin.threshold.toStringAsFixed(1)} allowed',
              xp: kBossWinXp,
              spec: CreatureSpec.forBoss(kWeekendBosses.indexWhere(
                      (BossDef d) => d.name == lastBossWin!.boss.name)
                  .clamp(0, kWeekendBosses.length - 1)),
              accent: widget.accent)
          : _WinPop(
              title: 'SLAIN',
              name: lastKill!.enemy.name,
              sub: 'after ${lastKill.fightDays} '
                  'day${lastKill.fightDays == 1 ? '' : 's'} of fighting',
              xp: (lastKill.enemy.sizeMult * 100).round().clamp(50, 500),
              spec: CreatureSpec.forEnemy(lastKill.enemy),
              accent: widget.accent),
    ).then((_) => _celebrating = false);
  }

  static String _num(double v) {
    final String s = v.round().toString();
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  static String _shortDate(String iso) {
    final DateTime? d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return '${monthName(d.month)} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final CampaignState c = CampaignEngine.compute(
      cal: widget.cal,
      logs: widget.logs,
      foods: widget.foods,
      fasted: widget.fasted.toSet(),
      runs: widget.runs,
      sleep: widget.sleep,
      startDate: widget.campaignStart,
    );
    final GoalState g = GoalEngine.compute(
      widget.cal,
      widget.logs,
      widget.foods,
      widget.fasted.toSet(),
      runs: widget.runs,
      sleep: widget.sleep,
      trainerLevel: widget.trainer.level,
      challenges: widget.challenges,
      prestige: widget.prestige,
      extraXp: c.xp,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeCelebrate(c));

    return Column(children: <Widget>[
      _fatBossStrip(c),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Row(
            children: List<Widget>.generate(4, (int i) {
          const List<String> labels = <String>[
            'FIGHT', 'HERO', 'BESTIARY', 'RECORDS'
          ];
          final bool on = _page == i;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _page = i),
              child: Container(
                margin: EdgeInsets.only(right: i < 3 ? 6 : 0),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: on
                      ? widget.accent.withValues(alpha: 0.16)
                      : kSurface0,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: on ? widget.accent : kBorder),
                ),
                child: Text(labels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: on ? widget.accent : Colors.grey[600])),
              ),
            ),
          );
        })),
      ),
      Expanded(
        child: switch (_page) {
          1 => _heroPage(c, g),
          2 => _bestiaryPage(c),
          3 => _recordsPage(c),
          _ => _fightPage(c),
        },
      ),
    ]);
  }

  // ── the final boss strip ──────────────────────────────────────────────

  Widget _fatBossStrip(CampaignState c) {
    final double frac = c.fatBossMax <= 0
        ? 0
        : (c.fatBossHp / c.fatBossMax).clamp(0.0, 1.0);
    final double lb = c.fatBossHp / 3500;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[
          Text('THE FINAL BOSS · FAT TO GOAL',
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Colors.grey[600])),
          Text(
              c.fatBossHp <= 0
                  ? 'DEFEATED'
                  : '${_num(c.fatBossHp)} cal ≈ ${lb.toStringAsFixed(1)} lb',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: c.fatBossHp <= 0
                      ? const Color(0xFF3CD6A3)
                      : Colors.grey[400])),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
              value: frac,
              minHeight: 5,
              backgroundColor: const Color(0xFF241417),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Color(0xFFB03A4A))),
        ),
      ]),
    );
  }

  // ── FIGHT ─────────────────────────────────────────────────────────────

  Widget _fightPage(CampaignState c) {
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
        children: <Widget>[
          if (c.activeBoss != null)
            _bossCard(c)
          else ...<Widget>[
            _enemyCard(c),
            const SizedBox(height: 12),
            _pendingCard(c),
          ],
          const SizedBox(height: 12),
          _playerBar(c),
          const SizedBox(height: 12),
          _combatLog(c),
        ]);
  }

  Widget _enemyCard(CampaignState c) {
    final double frac =
        c.enemyMaxHp <= 0 ? 0 : (c.enemyHp / c.enemyMaxHp).clamp(0.0, 1.0);
    final double pending =
        !c.weekendMode && (c.pendingDamage ?? 0) > 0 ? c.pendingDamage! : 0;
    if (pending > _lastPending + 25) {
      _flinchTick++;
    }
    _lastPending = pending;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(children: <Widget>[
        Text(c.enemy.zoneName.toUpperCase(),
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                color: Colors.grey[600])),
        const SizedBox(height: 6),
        _LivePortrait(
            spec: CreatureSpec.forEnemy(c.enemy),
            damage: 1 - frac,
            flinchTick: _flinchTick,
            size: 150),
        const SizedBox(height: 4),
        Text(c.enemy.name,
            style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: Color(0xFFEEEEEE))),
        const SizedBox(height: 12),
        Row(children: <Widget>[
          Expanded(
              child: _HpBar(
                  hp: c.enemyHp, maxHp: c.enemyMaxHp, pending: pending)),
          const SizedBox(width: 10),
          Text('${_num(c.enemyHp)} / ${_num(c.enemyMaxHp)}',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[400])),
        ]),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[
          Text('fighting since ${_shortDate(c.enemySpawnDate)}',
              style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          Text('${c.kills.length} slain',
              style: TextStyle(fontSize: 10, color: Colors.grey[600])),
        ]),
      ]),
    );
  }

  Widget _bossCard(CampaignState c) {
    final BossRecord b = c.activeBoss!;
    final int idx = kWeekendBosses
        .indexWhere((BossDef d) => d.name == b.boss.name)
        .clamp(0, kWeekendBosses.length - 1);
    final bool noMark = b.result == 'no_mark';
    final bool saturday = DateTime.now().weekday == DateTime.saturday;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF5A2D3A), width: 1.4)),
      child: Column(children: <Widget>[
        const Text('⚔ WEEKEND BOSS',
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                color: Color(0xFFCE4257))),
        const SizedBox(height: 6),
        _LivePortrait(
            spec: CreatureSpec.forBoss(idx),
            damage: 0,
            flinchTick: 0,
            size: 150),
        Text(b.boss.name,
            style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: Color(0xFFEEEEEE))),
        const SizedBox(height: 2),
        Text(b.boss.flavor,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11.5,
                fontStyle: FontStyle.italic,
                color: Colors.grey[500])),
        const SizedBox(height: 12),
        if (noMark)
          Text(
              saturday
                  ? 'No mark yet — weigh in this morning to start the fight.'
                  : 'No weigh-in since Thursday. He passes you by this '
                      'weekend — no win, no loss.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[400]))
        else ...<Widget>[
          _kv('THE MARK',
              '${b.markWeight!.toStringAsFixed(1)} lb · ${_shortDate(b.markDate!)}'),
          _kv('BEAT HIM',
              'gain less than +${b.threshold.toStringAsFixed(1)} lb by Monday morning'),
          _kv('YOUR AVERAGE',
              '+${b.avgGain.toStringAsFixed(2)} lb per unlogged day — win and it drops'),
          const SizedBox(height: 6),
          Text(
              DateTime.now().weekday == DateTime.monday
                  ? 'Weigh in NOW for the verdict. No weigh-in today = he wins.'
                  : 'Live the weekend. He weighs you Monday morning.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE0A9B4))),
        ],
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: kSurface0, borderRadius: BorderRadius.circular(8)),
          child: Text(
              '${c.enemy.name} waits, frozen at '
              '${((c.enemyHp / max(c.enemyMaxHp, 1)) * 100).round()}%',
              style: TextStyle(fontSize: 10.5, color: Colors.grey[500])),
        ),
      ]),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          SizedBox(
              width: 96,
              child: Text(k,
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: Colors.grey[600]))),
          Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFDDDDDD)))),
        ]),
      );

  Widget _pendingCard(CampaignState c) {
    final double? p = c.pendingDamage;
    String text;
    Color color;
    if (c.weekendMode) {
      text = 'Weekend. The road waits — the boss is the fight.';
      color = Colors.grey[500]!;
    } else if (p == null) {
      text = 'Nothing logged yet. Log food to swing — a silent weekday '
          'costs ${kUnloggedHit.round()} HP at midnight.';
      color = Colors.grey[400]!;
    } else if (p >= c.enemyHp && c.enemyHp > 0) {
      text = 'LETHAL — today\'s swing of ${_num(p)} finishes ${c.enemy.name} '
          'at midnight. Hold the line.';
      color = const Color(0xFFF0C040);
    } else if (p >= 0) {
      text = 'TODAY\'S SWING — ${_num(p)} pending. Settles at midnight.';
      color = widget.accent;
    } else {
      text = 'Over maintenance — ${c.enemy.name} heals ${_num(-p)} at '
          'midnight unless you claw it back.';
      color = const Color(0xFFCE4257);
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: kSurface0,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Row(children: <Widget>[
        Icon(
            p != null && p < 0
                ? Icons.warning_amber_rounded
                : Icons.flash_on_rounded,
            size: 18,
            color: color),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: color))),
      ]),
    );
  }

  Widget _playerBar(CampaignState c) {
    final double frac =
        c.playerMaxHp <= 0 ? 0 : (c.playerHp / c.playerMaxHp).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: kSurface0,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Row(children: <Widget>[
        Text('YOU',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: Colors.grey[500])),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: frac,
                minHeight: 10,
                backgroundColor: const Color(0xFF14201A),
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF3CD6A3))),
          ),
        ),
        const SizedBox(width: 10),
        Text('${c.playerHp.round()}/${c.playerMaxHp.round()} HP',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.grey[400])),
      ]),
    );
  }

  Widget _combatLog(CampaignState c) {
    final List<CombatEvent> tail = c.log.reversed.take(14).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('COMBAT LOG',
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                color: Colors.grey[600])),
        const SizedBox(height: 8),
        if (tail.isEmpty)
          Text('The road ahead is quiet. It won\'t stay that way.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]))
        else
          for (final CombatEvent e in tail)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                SizedBox(
                    width: 46,
                    child: Text(_shortDate(e.date),
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey[600]))),
                Expanded(
                    child: Text(e.text,
                        style: TextStyle(
                            fontSize: 11.5,
                            height: 1.3,
                            color: switch (e.kind) {
                              'kill' || 'boss_win' => const Color(0xFFF0C040),
                              'hit' || 'run' || 'regen' => const Color(0xFF9ADBC1),
                              'spawn' => Colors.grey[400],
                              _ => const Color(0xFFD98A94),
                            }))),
              ]),
            ),
      ]),
    );
  }

  // ── HERO ──────────────────────────────────────────────────────────────

  Widget _heroPage(CampaignState c, GoalState g) {
    final double leanness = widget.logs.isEmpty
        ? 0
        : MathEngine.progress(
            widget.cal.startBf, widget.logs.last.bf, widget.cal.targetBf);
    final int tier = g.level >= 15
        ? 3
        : g.level >= 8
            ? 2
            : g.level >= 4
                ? 1
                : 0;
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: kSurface1,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kBorder)),
            child: Column(children: <Widget>[
              SizedBox(
                  height: 150,
                  child: CustomPaint(
                      size: const Size(150, 150),
                      painter: HeroPainter(leanness, tier, widget.accent))),
              const SizedBox(height: 6),
              Text('LEVEL ${g.level} · ${g.rank.toUpperCase()}',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: widget.accent)),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                    value: g.xpForLevel <= 0
                        ? 0
                        : (g.xpIntoLevel / g.xpForLevel).clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: kSurface3,
                    valueColor: AlwaysStoppedAnimation<Color>(widget.accent)),
              ),
              const SizedBox(height: 4),
              Text('${g.xpIntoLevel} / ${g.xpForLevel} XP · '
                  'the same economy as GOALS',
                  style: TextStyle(fontSize: 10, color: Colors.grey[600])),
            ]),
          ),
          const SizedBox(height: 12),
          _statCard(
              'STRENGTH',
              Icons.fitness_center_rounded,
              c.strength,
              '×${c.strengthMult.toStringAsFixed(2)} damage',
              'Protein vs target, last 7 days. Hit it and you hit harder.',
              c.statHistory.map((StatSample s) => s.strength).toList()),
          _statCard(
              'VITALITY',
              Icons.favorite_rounded,
              c.vitality,
              '${c.playerMaxHp.round()} max HP',
              'Sleep, 7-night average. 8 hours = 120 HP, short nights = 80.',
              c.statHistory.map((StatSample s) => s.vitality).toList()),
          _statCard(
              'ENDURANCE',
              Icons.directions_run_rounded,
              c.endurance,
              c.endurance > 0 ? 'run attack armed' : 'run attack idle',
              'Running volume. A run beyond your usual mileage lands a hit.',
              c.statHistory.map((StatSample s) => s.endurance).toList()),
          _statCard(
              'DISCIPLINE',
              Icons.event_available_rounded,
              c.discipline,
              '+${c.regenPerDay.round()} HP per clean day',
              'Share of the last 30 days with intake logged.',
              c.statHistory.map((StatSample s) => s.discipline).toList()),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: kSurface0,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kBorder)),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: <Widget>[
                  _bigStat(_num(c.totalDamage), 'DAMAGE DEALT'),
                  _bigStat('${c.kills.length}', 'SLAIN'),
                  _bigStat('${c.bossWins}–${c.bossLosses}', 'BOSS RECORD'),
                  _bigStat('${c.koCount}', 'K.O.s'),
                ]),
          ),
        ]);
  }

  Widget _statCard(String name, IconData icon, double v, String effect,
      String desc, List<double> series) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: kSurface0,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Icon(icon, size: 15, color: widget.accent),
          const SizedBox(width: 6),
          Text(name,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                  color: Color(0xFFDDDDDD))),
          const Spacer(),
          Text(effect,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: widget.accent)),
        ]),
        const SizedBox(height: 8),
        Row(children: <Widget>[
          Expanded(
            flex: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: v.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: kSurface3,
                  valueColor: AlwaysStoppedAnimation<Color>(widget.accent)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: SizedBox(
                height: 22,
                child: CustomPaint(
                    size: const Size(double.infinity, 22),
                    painter: _SparkPainter(series,
                        widget.accent.withValues(alpha: 0.85)))),
          ),
        ]),
        const SizedBox(height: 6),
        Text(desc, style: TextStyle(fontSize: 10.5, color: Colors.grey[600])),
      ]),
    );
  }

  Widget _bigStat(String v, String label) => Column(children: <Widget>[
        Text(v,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Color(0xFFEEEEEE))),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: Colors.grey[600])),
      ]);

  // ── BESTIARY ──────────────────────────────────────────────────────────

  Widget _bestiaryPage(CampaignState c) {
    final int current = c.enemy.index;
    final int shown = current + 9; // everything met plus the road just ahead
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
        children: <Widget>[
          Text(
              '${c.kills.length} SLAIN · ${c.enemy.zoneName.toUpperCase()}',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Colors.grey[500])),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 0.82),
            itemCount: shown + 1,
            itemBuilder: (BuildContext ctx, int i) {
              final EnemyDef e = enemyAt(i);
              final bool killed = i < current;
              final bool now = i == current;
              final KillRecord? kr = killed && i < c.kills.length
                  ? c.kills[i]
                  : null;
              return Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: kSurface0,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: now ? widget.accent : kBorder,
                        width: now ? 1.4 : 1)),
                child: Column(children: <Widget>[
                  Expanded(
                    child: killed || now
                        ? CustomPaint(
                            size: const Size(64, 64),
                            painter:
                                CreaturePainter(CreatureSpec.forEnemy(e)))
                        : ColorFiltered(
                            colorFilter: const ColorFilter.mode(
                                Color(0xFF232323), BlendMode.srcIn),
                            child: CustomPaint(
                                size: const Size(64, 64),
                                painter: CreaturePainter(
                                    CreatureSpec.forEnemy(e)))),
                  ),
                  Text(killed || now ? e.name : '???',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w700,
                          color: now
                              ? widget.accent
                              : killed
                                  ? Colors.grey[400]
                                  : Colors.grey[700])),
                  Text(
                      now
                          ? 'NOW'
                          : kr != null
                              ? '${kr.fightDays}d'
                              : killed
                                  ? 'slain'
                                  : '',
                      style: TextStyle(
                          fontSize: 7.5, color: Colors.grey[600])),
                ]),
              );
            },
          ),
          const SizedBox(height: 16),
          Text('BOSS LEDGER',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Colors.grey[500])),
          const SizedBox(height: 8),
          if (c.bossLedger.isEmpty)
            Text('The first boss arrives Saturday.',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]))
          else
            for (final BossRecord b in c.bossLedger.reversed.take(10))
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: kSurface0,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kBorder)),
                child: Row(children: <Widget>[
                  Text(
                      switch (b.result) {
                        'won' => 'W',
                        'lost' => 'L',
                        _ => '–',
                      },
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: switch (b.result) {
                            'won' => const Color(0xFF3CD6A3),
                            'lost' => const Color(0xFFCE4257),
                            _ => Colors.grey[600],
                          })),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                        Text('${b.boss.name} · ${_shortDate(b.saturday)}',
                            style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFDDDDDD))),
                        Text(
                            b.result == 'no_mark'
                                ? 'no weigh-in — passed by'
                                : b.gain == null
                                    ? 'no Monday weigh-in — forfeit'
                                    : '${b.gain! >= 0 ? '+' : ''}'
                                        '${b.gain!.toStringAsFixed(1)} lb vs '
                                        '+${b.threshold.toStringAsFixed(1)} allowed',
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey[600])),
                      ])),
                ]),
              ),
        ]);
  }

  // ── RECORDS ───────────────────────────────────────────────────────────

  Widget _recordsPage(CampaignState c) {
    final double lbDealt = c.totalDamage / 3500;
    final List<String> dates = c.damageByDate.keys.toList()..sort();
    double window(int days) {
      final List<String> tail =
          dates.length > days ? dates.sublist(dates.length - days) : dates;
      if (tail.isEmpty) return 0;
      double sum = 0;
      for (final String d in tail) {
        sum += c.damageByDate[d] ?? 0;
      }
      return sum / tail.length;
    }

    final double? leanRetained =
        widget.logs.isEmpty || widget.cal.startLbm <= 0
            ? null
            : widget.logs.last.lbm / widget.cal.startLbm * 100;

    final RivalState rival = RivalEngine.compute(widget.logs,
        campaignStart: widget.campaignStart,
        resetDate: widget.cal.tdeeResetDate);

    final int? daysToGoal =
        MathEngine.daysToGoal(widget.logs, widget.cal.targetBf);
    final DateTime? killDate =
        MathEngine.goalDate(widget.logs, widget.cal.targetBf);

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 100),
        children: <Widget>[
          _recordsCard('LIFETIME', <Widget>[
            _recordRow('Total damage dealt',
                '${_num(c.totalDamage)} cal ≈ ${lbDealt.toStringAsFixed(1)} lb of fat'),
            _recordRow('Damage healed (went over)', '${_num(c.totalHealed)} cal'),
            _recordRow('Enemies slain', '${c.kills.length}'),
            _recordRow('Deepest ground', c.enemy.zoneName),
            _recordRow('Boss record', '${c.bossWins}–${c.bossLosses}'),
            _recordRow('Knockouts', '${c.koCount}'),
          ]),
          _recordsCard('RATE', <Widget>[
            _recordRow('Hit rate',
                '${(c.hitRate * 100).round()}% of weekdays'),
            _recordRow('Damage per day',
                '${_num(window(dates.length))} all-time · '
                '${_num(window(30))} last 30 · ${_num(window(7))} last 7'),
            _recordRow('Longest hit streak', '${c.bestHitStreak} days'),
            _recordRow(
                'Biggest single hit',
                c.biggestHit <= 0
                    ? '—'
                    : '${_num(c.biggestHit)} · ${_shortDate(c.biggestHitDate!)}'),
            _recordRow('Longest fight',
                c.longestFightDays == 0 ? '—' : '${c.longestFightDays} days'),
            _recordRow('Fastest kill',
                c.fastestKillDays == 0 ? '—' : '${c.fastestKillDays} days'),
          ]),
          _chartCard(
              'DAMAGE BY DAY OF WEEK',
              'Where the week actually goes.',
              _WeekdayBars(c.avgDamageByWeekday, widget.accent)),
          _chartCard(
              'CALORIES BY HOUR',
              'When the damage evaporates. Last 60 days.',
              _HourBars(c.caloriesByHour, widget.accent)),
          if (c.bossLedger.where((BossRecord b) => b.result != 'no_mark').length >= 2)
            _chartCard(
                'THE RATCHET',
                'The weekend benchmark. Falling means you\'re fixing weekends.',
                _RatchetLine(c.bossLedger, widget.accent)),
          _chartCard(
              'THE FINAL BOSS',
              'Fat between you and the goal, since day one.',
              _FatLine(widget.logs, widget.cal, const Color(0xFFB03A4A))),
          _recordsCard('BODY', <Widget>[
            _recordRow('Final boss HP',
                '${_num(c.fatBossHp)} cal ≈ ${(c.fatBossHp / 3500).toStringAsFixed(1)} lb'),
            _recordRow(
                'Damage dealt to it',
                c.fatBossMax <= 0
                    ? '—'
                    : '${(100 * (1 - c.fatBossHp / c.fatBossMax)).clamp(0, 100).round()}% down'),
            _recordRow(
                'Projected kill',
                killDate == null || daysToGoal == null
                    ? 'no pace yet'
                    : '${monthName(killDate.month)} ${killDate.day} · $daysToGoal days at pace'),
            _recordRow(
                'Lean mass retained',
                leanRetained == null
                    ? '—'
                    : '${leanRetained.toStringAsFixed(1)}% of day one'),
            _recordRow(
                'Chad',
                !rival.hasData
                    ? 'waiting at the start line'
                    : rival.gap <= 0
                        ? 'you lead by ${(-rival.gap).toStringAsFixed(1)} lb'
                        : 'ahead by ${rival.gap.toStringAsFixed(1)} lb'),
          ]),
        ]);
  }

  Widget _recordsCard(String title, List<Widget> rows) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: kSurface1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kBorder)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(title,
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                  color: Colors.grey[600])),
          const SizedBox(height: 6),
          ...rows,
        ]),
      );

  Widget _recordRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Expanded(
              child: Text(k,
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]))),
          Text(v,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFDDDDDD))),
        ]),
      );

  Widget _chartCard(String title, String sub, Widget chart) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: kSurface1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kBorder)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(title,
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                  color: Colors.grey[600])),
          Text(sub, style: TextStyle(fontSize: 10, color: Colors.grey[700])),
          const SizedBox(height: 10),
          SizedBox(height: 90, width: double.infinity, child: chart),
        ]),
      );
}

// ── the win popup ──────────────────────────────────────────────────────

class _WinPop extends StatefulWidget {
  final String title;
  final String name;
  final String sub;
  final int xp;
  final CreatureSpec spec;
  final Color accent;
  const _WinPop(
      {required this.title,
      required this.name,
      required this.sub,
      required this.xp,
      required this.spec,
      required this.accent});

  @override
  State<_WinPop> createState() => _WinPopState();
}

class _WinPopState extends State<_WinPop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..forward();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kSurface2,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (BuildContext ctx, Widget? _) {
          final double t = _ctl.value;
          final double pop =
              Curves.elasticOut.transform(min(1, t * 1.6)).clamp(0.0, 1.2);
          final int xpShown =
              (widget.xp * Curves.easeOut.transform(min(1, t * 1.3))).round();
          return Stack(alignment: Alignment.topCenter, children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                Text(widget.title,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                        color: widget.accent)),
                const SizedBox(height: 8),
                Transform.scale(
                  scale: pop,
                  child: SizedBox(
                      height: 110,
                      child: CustomPaint(
                          size: const Size(110, 110),
                          painter: CreaturePainter(widget.spec, damage: 1))),
                ),
                Text(widget.name,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFEEEEEE))),
                Text(widget.sub,
                    style:
                        TextStyle(fontSize: 11.5, color: Colors.grey[500])),
                const SizedBox(height: 10),
                Text('+$xpShown XP',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: widget.accent)),
                const SizedBox(height: 10),
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text('ONWARD',
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                            color: widget.accent))),
              ]),
            ),
            IgnorePointer(
              child: SizedBox(
                  height: 260,
                  width: 300,
                  child: CustomPaint(
                      painter: _ConfettiPainter(t, widget.accent))),
            ),
          ]);
        },
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final double t; // 0..1
  final Color accent;
  const _ConfettiPainter(this.t, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) {
      return;
    }
    final Random rng = Random(7);
    final List<Color> colors = <Color>[
      accent,
      const Color(0xFFF0C040),
      const Color(0xFFCE4257),
      const Color(0xFF3CD6A3),
    ];
    for (int i = 0; i < 36; i++) {
      final double x0 = rng.nextDouble() * size.width;
      final double vy = 60 + rng.nextDouble() * 140;
      final double sway = (rng.nextDouble() - 0.5) * 50;
      final double y = -10 + t * (size.height * 0.6 + vy);
      final double x = x0 + sin(t * 6 + i) * 8 + sway * t;
      final double fade = (1 - t).clamp(0.0, 1.0);
      final Paint p = Paint()
        ..color = colors[i % colors.length].withValues(alpha: 0.85 * fade);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * 8 + i.toDouble());
      canvas.drawRect(
          Rect.fromCenter(
              center: Offset.zero,
              width: 5 + (i % 3).toDouble(),
              height: 3.4),
          p);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) =>
      old.t != t || old.accent != accent;
}

// ── living portrait ───────────────────────────────────────────────────
// Owns its own ticker so 60fps idle life never re-runs the engine — only
// this little CustomPaint repaints.

class _LivePortrait extends StatefulWidget {
  final CreatureSpec spec;
  final double damage;
  final int flinchTick; // bump it and the creature recoils once
  final double size;
  const _LivePortrait(
      {required this.spec,
      required this.damage,
      required this.flinchTick,
      required this.size});

  @override
  State<_LivePortrait> createState() => _LivePortraitState();
}

class _LivePortraitState extends State<_LivePortrait>
    with TickerProviderStateMixin {
  late final Ticker _ticker;
  late final AnimationController _flinch;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((Duration d) {
      setState(() => _t = d.inMicroseconds / 1e6);
    })
      ..start();
    _flinch = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 380));
  }

  @override
  void didUpdateWidget(_LivePortrait old) {
    super.didUpdateWidget(old);
    if (widget.flinchTick != old.flinchTick) {
      _flinch.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _flinch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double recoil =
        _flinch.isAnimating ? 1 - Curves.easeOut.transform(_flinch.value) : 0;
    return SizedBox(
        height: widget.size,
        child: CustomPaint(
            size: Size(widget.size, widget.size),
            painter: CreaturePainter(widget.spec,
                damage: widget.damage, anim: _t, flinch: recoil)));
  }
}

// ── enemy HP bar with the ghost segment ───────────────────────────────
// The hatched slice is today's pending hit, being carved off live as food
// gets logged. It becomes real at midnight.

class _HpBar extends StatelessWidget {
  final double hp;
  final double maxHp;
  final double pending;
  const _HpBar(
      {required this.hp, required this.maxHp, this.pending = 0});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        height: 12,
        width: double.infinity,
        child: CustomPaint(painter: _HpBarPainter(hp, maxHp, pending)));
  }
}

class _HpBarPainter extends CustomPainter {
  final double hp;
  final double maxHp;
  final double pending;
  const _HpBarPainter(this.hp, this.maxHp, this.pending);

  @override
  void paint(Canvas canvas, Size size) {
    final RRect frame = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(4));
    canvas.drawRRect(frame, Paint()..color = const Color(0xFF241417));
    if (maxHp <= 0) {
      return;
    }
    final double ghostFrac = (hp / maxHp).clamp(0.0, 1.0);
    final double solidFrac = ((hp - pending) / maxHp).clamp(0.0, 1.0);
    canvas.save();
    canvas.clipRRect(frame);
    // What will remain after midnight.
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * solidFrac, size.height),
        Paint()..color = const Color(0xFFCE4257));
    // The slice being carved off today: dimmed + hatched.
    if (ghostFrac > solidFrac) {
      final Rect ghost = Rect.fromLTWH(size.width * solidFrac, 0,
          size.width * (ghostFrac - solidFrac), size.height);
      canvas.drawRect(
          ghost, Paint()..color = const Color(0xFFCE4257).withValues(alpha: 0.30));
      final Paint stripe = Paint()
        ..color = const Color(0xFFE88A98).withValues(alpha: 0.55)
        ..strokeWidth = 1.6;
      canvas.save();
      canvas.clipRect(ghost);
      for (double x = ghost.left - size.height;
          x < ghost.right + size.height;
          x += 6) {
        canvas.drawLine(Offset(x, size.height + 2),
            Offset(x + size.height + 4, -2), stripe);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HpBarPainter old) =>
      old.hp != hp || old.maxHp != maxHp || old.pending != pending;
}

// ── chart painters ────────────────────────────────────────────────────

class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  const _SparkPainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final double lo = values.reduce(min);
    final double hi = values.reduce(max);
    final double span = (hi - lo).abs() < 1e-9 ? 1 : hi - lo;
    final Path p = Path();
    for (int i = 0; i < values.length; i++) {
      final double x = size.width * i / (values.length - 1);
      final double y =
          size.height - ((values[i] - lo) / span) * (size.height - 2) - 1;
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    canvas.drawPath(
        p,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color;
}

class _WeekdayBars extends StatelessWidget {
  final Map<int, double> byWeekday;
  final Color accent;
  const _WeekdayBars(this.byWeekday, this.accent);

  @override
  Widget build(BuildContext context) {
    const List<String> names = <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final double peak = byWeekday.values.isEmpty
        ? 1
        : max(byWeekday.values.reduce(max), 1);
    return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List<Widget>.generate(7, (int i) {
          final double v = byWeekday[i + 1] ?? 0;
          final bool weekend = i >= 5;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
                Text(v > 0 ? '${(v / 100).round() * 100 ~/ 100 * 100}' : '',
                    style:
                        TextStyle(fontSize: 7.5, color: Colors.grey[600])),
                const SizedBox(height: 2),
                Container(
                    height: max(3, 62 * v / peak),
                    decoration: BoxDecoration(
                        color: weekend
                            ? Colors.grey[800]
                            : accent.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(3))),
                const SizedBox(height: 4),
                Text(names[i],
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey[600])),
              ]),
            ),
          );
        }));
  }
}

class _HourBars extends StatelessWidget {
  final Map<int, double> byHour;
  final Color accent;
  const _HourBars(this.byHour, this.accent);

  @override
  Widget build(BuildContext context) {
    final double peak =
        byHour.values.isEmpty ? 1 : max(byHour.values.reduce(max), 1);
    return Column(children: <Widget>[
      Expanded(
        child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List<Widget>.generate(24, (int h) {
              final double v = byHour[h] ?? 0;
              return Expanded(
                child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 0.8),
                    height: max(2, 66 * v / peak),
                    decoration: BoxDecoration(
                        color: h >= 20 || h < 5
                            ? const Color(0xFF7A5CD6).withValues(alpha: 0.85)
                            : accent.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(2))),
              );
            })),
      ),
      const SizedBox(height: 4),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[
        for (final String t in <String>['12a', '6a', '12p', '6p', '11p'])
          Text(t, style: TextStyle(fontSize: 8, color: Colors.grey[600])),
      ]),
    ]);
  }
}

class _RatchetLine extends StatelessWidget {
  final List<BossRecord> ledger;
  final Color accent;
  const _RatchetLine(this.ledger, this.accent);

  @override
  Widget build(BuildContext context) {
    final List<double> vals = <double>[
      for (final BossRecord b in ledger)
        if (b.result != 'no_mark') b.threshold
    ];
    return CustomPaint(
        size: const Size(double.infinity, 90),
        painter: _SparkPainter(vals, accent));
  }
}

class _FatLine extends StatelessWidget {
  final List<DailyLog> logs;
  final UserCalibration cal;
  final Color color;
  const _FatLine(this.logs, this.cal, this.color);

  @override
  Widget build(BuildContext context) {
    final List<double> vals = <double>[
      for (final DailyLog l in logs)
        max(0, (l.fatMass - l.lbm * cal.targetBf / (1 - cal.targetBf)) * 3500)
    ];
    return CustomPaint(
        size: const Size(double.infinity, 90),
        painter: _SparkPainter(vals, color));
  }
}
