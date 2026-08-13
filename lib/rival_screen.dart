import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'campaign.dart';
import 'creatures.dart';
import 'food.dart';
import 'main.dart';
import 'sleep.dart';
import 'trainer.dart';

// ═══════════════════════════════════════════════════════════════════════
// THE RIVALRY — tap Chad's card and get the whole feud: the race chart
// with every lead change, the week-by-week rounds record, the stats, and
// the full archive of everything he's ever said.
// ═══════════════════════════════════════════════════════════════════════

class RivalScreen extends StatelessWidget {
  final UserCalibration cal;
  final List<DailyLog> logs;
  final List<FoodEntry> foods;
  final List<String> fasted;
  final List<RunRecord> runs;
  final List<SleepEntry> sleep;
  final String campaignStart;
  final Color accent;

  const RivalScreen({
    super.key,
    required this.cal,
    required this.logs,
    required this.foods,
    required this.fasted,
    required this.runs,
    required this.sleep,
    required this.campaignStart,
    required this.accent,
  });

  static String _short(String iso) {
    final DateTime? d = DateTime.tryParse(iso);
    return d == null ? iso : '${monthName(d.month)} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    // Chad gets the K.O. list so he can bring it up. Rude, by design.
    final CampaignState camp = CampaignEngine.compute(
      cal: cal,
      logs: logs,
      foods: foods,
      fasted: fasted.toSet(),
      runs: runs,
      sleep: sleep,
      startDate: campaignStart,
    );
    final List<String> koDates = <String>[
      for (final CombatEvent e in camp.log)
        if (e.kind == 'ko') e.date
    ];
    final RivalState r = RivalEngine.compute(logs,
        campaignStart: campaignStart,
        resetDate: cal.tdeeResetDate,
        historyDays: 100000,
        koDates: koDates);
    final List<RivalRound> rounds = RivalEngine.rounds(logs,
        campaignStart: campaignStart, resetDate: cal.tdeeResetDate);

    return Scaffold(
      backgroundColor: kBgDeep,
      appBar: AppBar(
          title: const Text('THE RIVALRY',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5)),
          backgroundColor: kBgDeep,
          elevation: 0),
      body: SafeArea(
        child: !r.hasData
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        const ChadAvatarLive(mood: 1, size: 120),
                        const SizedBox(height: 12),
                        Text('“${r.line}”',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                                color: Colors.grey[400])),
                      ]),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                children: <Widget>[
                  _header(r),
                  const SizedBox(height: 12),
                  _chartCard(r),
                  const SizedBox(height: 12),
                  _roundsCard(rounds),
                  const SizedBox(height: 12),
                  _statsCard(r, rounds),
                  const SizedBox(height: 12),
                  _archiveCard(r, koDates),
                ],
              ),
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: kSurface1,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kBorder)),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title,
                  style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.4,
                      color: Colors.grey[600])),
              const SizedBox(height: 8),
              ...children,
            ]),
      );

  Widget _header(RivalState r) {
    final bool ahead = r.gap > 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kSurface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(children: <Widget>[
        ChadAvatarLive(mood: r.mood, size: 130),
        const SizedBox(height: 8),
        Text('“${r.line}”',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                height: 1.4,
                color: Colors.grey[300])),
        const SizedBox(height: 12),
        Text(
            ahead
                ? 'He\'s ${r.gap.toStringAsFixed(1)} lb ahead'
                : 'You lead by ${(-r.gap).toStringAsFixed(1)} lb',
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: ahead
                    ? const Color(0xFFCE4257)
                    : const Color(0xFF3CD6A3))),
        Text(
            'you ${r.yourTrend.toStringAsFixed(1)} (trend) · '
            'him ${r.chadWeight.toStringAsFixed(1)} · '
            'racing since ${_short(r.anchorDate)}',
            style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      ]),
    );
  }

  Widget _chartCard(RivalState r) => _card('THE RACE', <Widget>[
        SizedBox(
            height: 170,
            width: double.infinity,
            child: RivalChart(
                series: r.series, accent: accent, markLeadChanges: true)),
        const SizedBox(height: 6),
        Row(children: <Widget>[
          _legendDot(accent, 'you (trend)'),
          const SizedBox(width: 14),
          _legendDot(const Color(0xFFCE4257), 'Chad, −1 lb/week'),
          const Spacer(),
          Text('${_leadChanges(r.series)} lead changes',
              style: TextStyle(fontSize: 10, color: Colors.grey[600])),
        ]),
      ]);

  Widget _legendDot(Color c, String label) => Row(children: <Widget>[
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[500])),
      ]);

  static int _leadChanges(List<RivalPoint> series) {
    int changes = 0;
    for (int i = 1; i < series.length; i++) {
      final double a = series[i - 1].you - series[i - 1].chad;
      final double b = series[i].you - series[i].chad;
      if ((a > 0) != (b > 0) && a != 0) {
        changes++;
      }
    }
    return changes;
  }

  Widget _roundsCard(List<RivalRound> rounds) {
    final int w = rounds.where((RivalRound r) => r.result == 'won').length;
    final int l = rounds.where((RivalRound r) => r.result == 'lost').length;
    final List<RivalRound> recent =
        rounds.length > 16 ? rounds.sublist(rounds.length - 16) : rounds;
    return _card('ROUNDS — DROP THE POUND OR LOSE THE WEEK', <Widget>[
      Text('You $w — $l Chad',
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: w >= l ? const Color(0xFF3CD6A3) : const Color(0xFFCE4257))),
      const SizedBox(height: 8),
      Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final RivalRound r in recent)
              Tooltip(
                message:
                    'week ${r.index} · ${_short(r.start)}${r.delta == null ? '' : ' · ${r.delta! >= 0 ? '+' : ''}${r.delta!.toStringAsFixed(1)} lb'}',
                child: Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: switch (r.result) {
                        'won' => const Color(0xFF17362B),
                        'lost' => const Color(0xFF3A1A20),
                        _ => kSurface0,
                      },
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: switch (r.result) {
                        'won' => const Color(0xFF3CD6A3),
                        'lost' => const Color(0xFFCE4257),
                        _ => kBorder,
                      })),
                  child: Text(
                      switch (r.result) {
                        'won' => 'W',
                        'lost' => 'L',
                        _ => '·',
                      },
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: switch (r.result) {
                            'won' => const Color(0xFF3CD6A3),
                            'lost' => const Color(0xFFCE4257),
                            _ => Colors.grey[600],
                          })),
                ),
              ),
          ]),
      const SizedBox(height: 6),
      Text('A week with no weigh-ins judges nothing.',
          style: TextStyle(fontSize: 10, color: Colors.grey[700])),
    ]);
  }

  Widget _statsCard(RivalState r, List<RivalRound> rounds) {
    // Lead accounting straight off the daily series.
    int youDays = 0, chadDays = 0;
    double bestYou = 0, bestChad = 0;
    for (final RivalPoint p in r.series) {
      final double g = p.you - p.chad;
      if (g < 0) {
        youDays++;
        bestYou = max(bestYou, -g);
      } else {
        chadDays++;
        bestChad = max(bestChad, g);
      }
    }
    // Who reaches your goal weight first, at current paces?
    final double goalW = logs.isEmpty
        ? cal.startWeight * (1 - cal.targetBf) / (1 - cal.startBf)
        : MathEngine.dynamicTargetWeight(logs.last.lbm, cal.targetBf);
    final int chadDaysToGoal =
        r.chadWeight <= goalW ? 0 : ((r.chadWeight - goalW) * 7).ceil();
    final DateTime chadArrives =
        DateTime.now().add(Duration(days: chadDaysToGoal));
    final DateTime? youArrive = MathEngine.goalDate(logs, cal.targetBf);

    String fmt(DateTime d) => '${monthName(d.month)} ${d.day}';
    return _card('HEAD TO HEAD', <Widget>[
      _row('Days in the lead',
          'you $youDays · him $chadDays'),
      _row('Your biggest lead',
          bestYou > 0 ? '${bestYou.toStringAsFixed(1)} lb' : '—'),
      _row('His biggest lead',
          bestChad > 0 ? '${bestChad.toStringAsFixed(1)} lb' : '—'),
      _row('He reaches your goal weight', fmt(chadArrives)),
      _row(
          'You reach it',
          youArrive == null
              ? 'no downward pace right now'
              : fmt(youArrive)),
      if (youArrive != null && youArrive.isBefore(chadArrives))
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('You get there first. Don\'t tell him yet.',
              style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: Colors.grey[500])),
        ),
    ]);
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: <Widget>[
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

  Widget _archiveCard(RivalState r, List<String> koDates) {
    final DateTime today = DateTime.now();
    final DateTime anchor = DateTime.tryParse(r.anchorDate) ?? today;
    final int span = min(today.difference(anchor).inDays, 45);
    final List<Widget> rows = <Widget>[];
    for (int back = 0; back <= span; back++) {
      final DateTime day = today.subtract(Duration(days: back));
      // Rebuild that day's gap off the stored series when we have it.
      final String key = formatDate(day);
      RivalPoint? p;
      for (final RivalPoint q in r.series) {
        if (q.date == key) {
          p = q;
          break;
        }
      }
      if (p == null) {
        continue;
      }
      final (int mood, String line) = RivalEngine.moodLine(
          p.you - p.chad, day,
          recentKo: back == 0 &&
              koDates.any((String d) =>
                  d.compareTo(formatDate(
                          today.subtract(const Duration(days: 2)))) >=
                  0));
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child:
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          SizedBox(
              width: 52,
              child: Text(_short(key),
                  style: TextStyle(fontSize: 10, color: Colors.grey[600]))),
          SizedBox(
              width: 18,
              child: Text(
                  switch (mood) {
                    0 => '😎',
                    2 => '😰',
                    3 => '😤',
                    _ => '😏',
                  },
                  style: const TextStyle(fontSize: 11))),
          Expanded(
              child: Text('“$line”',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontStyle: FontStyle.italic,
                      height: 1.3,
                      color: Colors.grey[400]))),
        ]),
      ));
    }
    return _card('EVERYTHING HE\'S SAID', rows);
  }
}

// ── the living Chad ─────────────────────────────────────────────────────

class ChadAvatarLive extends StatefulWidget {
  final int mood;
  final double size;
  const ChadAvatarLive({super.key, required this.mood, required this.size});

  @override
  State<ChadAvatarLive> createState() => _ChadAvatarLiveState();
}

class _ChadAvatarLiveState extends State<ChadAvatarLive>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((Duration d) {
      setState(() => _t = d.inMicroseconds / 1e6);
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
            size: Size(widget.size, widget.size),
            painter: ChadPainter(widget.mood, anim: _t)));
  }
}

// ── the race chart, shared by the card and this screen ─────────────────

class RivalChart extends StatelessWidget {
  final List<RivalPoint> series;
  final Color accent;
  final bool markLeadChanges;
  const RivalChart(
      {super.key,
      required this.series,
      required this.accent,
      this.markLeadChanges = false});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
        size: const Size(double.infinity, double.infinity),
        painter: _RivalChartPainter(series, accent, markLeadChanges));
  }
}

class _RivalChartPainter extends CustomPainter {
  final List<RivalPoint> series;
  final Color accent;
  final bool markLeadChanges;
  const _RivalChartPainter(this.series, this.accent, this.markLeadChanges);

  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2) {
      return;
    }
    double lo = double.infinity, hi = -double.infinity;
    for (final RivalPoint p in series) {
      lo = min(lo, min(p.you, p.chad));
      hi = max(hi, max(p.you, p.chad));
    }
    final double span = (hi - lo).abs() < 1e-9 ? 1 : hi - lo;
    double yFor(double v) =>
        size.height - ((v - lo) / span) * (size.height - 6) - 3;
    double xFor(int i) => size.width * i / (series.length - 1);

    Path build(double Function(RivalPoint) pick) {
      final Path path = Path();
      for (int i = 0; i < series.length; i++) {
        final double x = xFor(i);
        final double y = yFor(pick(series[i]));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      return path;
    }

    canvas.drawPath(
        build((RivalPoint p) => p.chad),
        Paint()
          ..color = const Color(0xFFCE4257).withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8);
    canvas.drawPath(
        build((RivalPoint p) => p.you),
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round);

    if (markLeadChanges) {
      final Paint dot = Paint()..color = const Color(0xFFF0C040);
      for (int i = 1; i < series.length; i++) {
        final double a = series[i - 1].you - series[i - 1].chad;
        final double b = series[i].you - series[i].chad;
        if ((a > 0) != (b > 0)) {
          final double y = yFor((series[i].you + series[i].chad) / 2);
          canvas.drawCircle(Offset(xFor(i), y), 3.4, dot);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_RivalChartPainter old) =>
      old.series != series ||
      old.accent != accent ||
      old.markLeadChanges != markLeadChanges;
}
