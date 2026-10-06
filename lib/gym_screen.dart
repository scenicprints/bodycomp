import 'dart:async';

import 'package:flutter/material.dart';

import 'main.dart';
import 'gymboard_bridge.dart';

// ═══════════════════════════════════════════════════════════════════════
// GYM — a window onto the board, nothing more.
//
// Gymboard owns the workout: you pick it on its own phone app, the TV
// runs it. This screen never drives it, it reports. That keeps one source
// of truth for a session and means a dropped connection here can never
// desync what the TV is doing.
//
// The history comes in as a prop, already cached by the app, so this
// screen renders instantly offline. Only the live session is polled, and
// only while this tab is actually in front.
// ═══════════════════════════════════════════════════════════════════════

class GymScreen extends StatefulWidget {
  final Color accent;
  final bool active;
  final List<GymboardWorkout> workouts;
  final Future<void> Function() onRefresh;

  const GymScreen({
    super.key,
    required this.accent,
    required this.active,
    required this.workouts,
    required this.onRefresh,
  });

  @override
  State<GymScreen> createState() => _GymScreenState();
}

class _GymScreenState extends State<GymScreen> {
  GymboardSession? _session;
  Timer? _poll;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(GymScreen old) {
    super.didUpdateWidget(old);
    // Polling a TV nobody is looking at is a waste of a radio.
    if (widget.active && !old.active) _start();
    if (!widget.active && old.active) _stop();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    _tick();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
  }

  void _stop() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _tick() async {
    final GymboardSession? s = await fetchGymboardSession();
    if (!mounted || s == null) return;
    setState(() => _session = s);
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onRefresh();
    await _tick();
    if (mounted) setState(() => _busy = false);
  }

  // ── slices of the history ────────────────────────────────────────────

  List<GymboardWorkout> get _thisWeek {
    final DateTime cut =
        DateTime.now().subtract(const Duration(days: 7));
    return widget.workouts
        .where((GymboardWorkout w) => w.at.isAfter(cut))
        .toList();
  }

  int _minutes(List<GymboardWorkout> w) =>
      w.fold(0, (int a, GymboardWorkout x) => a + x.ms) ~/ 60000;

  int _reps(List<GymboardWorkout> w) =>
      w.fold(0, (int a, GymboardWorkout x) => a + x.reps);

  @override
  Widget build(BuildContext context) {
    final List<GymboardWorkout> all = widget.workouts;
    final List<GymboardWorkout> week = _thisWeek;
    final int streak = gymStreak(all);

    return Scaffold(
      backgroundColor: kBgDeep,
      body: SafeArea(
        child: RefreshIndicator(
          color: widget.accent,
          backgroundColor: kSurface2,
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
            children: <Widget>[
              if (_session?.live ?? false) _liveCard(),
              _weekCard(week, streak),
              const SizedBox(height: 14),
              _lifetimeCard(all),
              const SizedBox(height: 14),
              _historyCard(all),
            ],
          ),
        ),
      ),
    );
  }

  // ── pieces ───────────────────────────────────────────────────────────

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: kSurface1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: child,
      );

  Widget _label(String t) => Text(t,
      style: TextStyle(
          color: Colors.grey[600],
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700));

  Widget _stat(String value, String caption) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value,
              style: const TextStyle(
                  color: Color(0xFFEEEEEE),
                  fontSize: 26,
                  fontWeight: FontWeight.w300,
                  height: 1.1)),
          const SizedBox(height: 3),
          Text(caption,
              style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 10,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700)),
        ],
      );

  Widget _liveCard() {
    final GymboardSession s = _session!;
    final String what = s.phase == 'resting'
        ? 'RESTING'
        : s.phase == 'warmup'
            ? 'WARMING UP'
            : 'CIRCUIT ${s.circuit + 1}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: kSurface1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: widget.accent)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                      color: widget.accent, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text('ON THE TV NOW',
                  style: TextStyle(
                      color: widget.accent,
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            Text(what,
                style: const TextStyle(
                    color: Color(0xFFEEEEEE),
                    fontSize: 24,
                    fontWeight: FontWeight.w300)),
            if (s.startedAt != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                  'started ${TimeOfDay.fromDateTime(s.startedAt!).format(context)}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _weekCard(List<GymboardWorkout> week, int streak) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _label('LAST 7 DAYS'),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                _stat('${week.length}', 'SESSIONS'),
                _stat('${_minutes(week)}', 'MINUTES'),
                _stat('${_reps(week)}', 'REPS'),
                _stat('$streak', 'DAY STREAK'),
              ],
            ),
          ],
        ),
      );

  Widget _lifetimeCard(List<GymboardWorkout> all) {
    final int mins = _minutes(all);
    final String hrs = (mins / 60).toStringAsFixed(1);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _label('ALL TIME'),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              _stat('${all.length}', 'WORKOUTS'),
              _stat(hrs, 'HOURS'),
              _stat('${_reps(all)}', 'REPS'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _historyCard(List<GymboardWorkout> all) {
    if (all.isEmpty) {
      return _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _label('HISTORY'),
            const SizedBox(height: 12),
            Text(
                _busy
                    ? 'Reading the board...'
                    : 'Nothing finished yet. Start a routine on the board '
                        'and it shows up here.',
                style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          ],
        ),
      );
    }

    final List<GymboardWorkout> recent = all.reversed.take(20).toList();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _label('HISTORY'),
          const SizedBox(height: 6),
          for (final GymboardWorkout w in recent)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(w.label,
                            style: const TextStyle(
                                color: Color(0xFFEEEEEE),
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(w.date,
                            style: TextStyle(
                                color: Colors.grey[600], fontSize: 11.5)),
                      ],
                    ),
                  ),
                  Text('${w.ms ~/ 60000} min',
                      style:
                          TextStyle(color: Colors.grey[500], fontSize: 13)),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 54,
                    child: Text('${w.reps}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            color: widget.accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
