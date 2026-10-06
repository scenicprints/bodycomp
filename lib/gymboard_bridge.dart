import 'dart:convert';

import 'package:http/http.dart' as http;

// ═══════════════════════════════════════════════════════════════════════
// GYMBOARD BRIDGE — reads what the gym TV already knows.
//
// Gymboard (scenicprints/gymboard) keeps two documents in the same
// Firestore project the foos league and Parchis live in:
//
//   gymboard/session   what is happening right now, or phase 'idle'
//   gymboard/history   { done: [ {routineId, at, ms, reps} ] }
//
// This reads both over the Firestore REST API rather than pulling in
// cloud_firestore, which would mean google-services.json, native config
// and a change to the cloud build for two reads. `http` is already here.
//
// Read only. Gymboard owns that data and this app never writes it.
// ═══════════════════════════════════════════════════════════════════════

const String _project = 'foos-6ecf3';
const String _apiKey = 'AIzaSyC2bOtXmNLzwJy3QsDkk1tQRBD_wMdhzcM';

String get _docBase =>
    'https://firestore.googleapis.com/v1/projects/$_project/databases/(default)/documents/gymboard';

// ── one finished workout ────────────────────────────────────────────────

class GymboardWorkout {
  final String routineId;
  final DateTime at;
  final int ms;
  final int reps;

  /// Only present if Gymboard wrote one. The routine names live in that
  /// app's JS bundle, not in Firestore, and this app is not going to parse
  /// someone else's JavaScript to get them. Until Gymboard records a name,
  /// [label] derives something honest from the id instead.
  final String? name;

  const GymboardWorkout({
    required this.routineId,
    required this.at,
    required this.ms,
    required this.reps,
    this.name,
  });

  /// `l1-r7` becomes `LEVEL 1 - ROUTINE 7`. Anything that does not match
  /// falls back to the raw id rather than inventing a shape it does not have.
  String get label {
    if (name != null && name!.isNotEmpty) return name!;
    final RegExpMatch? m =
        RegExp(r'^l(\d+)-r(\d+)$').firstMatch(routineId);
    if (m == null) return routineId;
    return 'LEVEL ${m.group(1)} · ROUTINE ${m.group(2)}';
  }

  /// `yyyy-MM-dd`, the key every other part of this app dates things by.
  String get date =>
      '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';

  Duration get duration => Duration(milliseconds: ms);

  /// A circuit workout is not a run and there is no heart rate here, so
  /// this is deliberately conservative: roughly 8 kcal a minute of actual
  /// work. It exists so the campaign has a number to hit with, not to
  /// pretend at precision the data does not have.
  double get estimatedKcal => (ms / 60000.0) * 8.0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'routineId': routineId,
        'at': at.toIso8601String(),
        'ms': ms,
        'reps': reps,
        if (name != null) 'name': name,
      };

  factory GymboardWorkout.fromJson(Map<String, dynamic> j) => GymboardWorkout(
        routineId: (j['routineId'] ?? '') as String,
        at: DateTime.tryParse((j['at'] ?? '') as String) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        ms: (j['ms'] as num?)?.toInt() ?? 0,
        reps: (j['reps'] as num?)?.toInt() ?? 0,
        name: j['name'] as String?,
      );
}

/// What the TV is showing. `phase` is 'idle' when nobody is working out.
class GymboardSession {
  final String phase;
  final String? routineId;
  final DateTime? startedAt;
  final int circuit;
  final int nextCircuit;
  final DateTime? restEndsAt;

  const GymboardSession({
    required this.phase,
    this.routineId,
    this.startedAt,
    this.circuit = 0,
    this.nextCircuit = 0,
    this.restEndsAt,
  });

  bool get live => phase != 'idle' && phase != 'done' && phase.isNotEmpty;

  /// Gymboard's state is declarative: it records when rest ends, never how
  /// long is left, so every reader works the remainder out from its own
  /// clock and a stalled phone cannot freeze the number.
  int get restLeftSec {
    final DateTime? e = restEndsAt;
    if (e == null) return 0;
    final int ms = e.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  int get elapsedSec {
    final DateTime? s = startedAt;
    if (s == null) return 0;
    return DateTime.now().difference(s).inSeconds;
  }

  /// `l3-r2` is level 3. Zero when the id is not that shape.
  int get level {
    final RegExpMatch? m =
        RegExp(r'^l(\d+)-r\d+$').firstMatch(routineId ?? '');
    return m == null ? 0 : (int.tryParse(m.group(1) ?? '') ?? 0);
  }

  /// What to put on a wrist: short, and true whatever the phase.
  String get watchPhase {
    switch (phase) {
      case 'warmup':
        return 'WARM UP';
      case 'resting':
        return 'REST';
      case 'running':
        return 'CIRCUIT ${circuit + 1}';
      case 'done':
        return 'DONE';
      default:
        return phase.toUpperCase();
    }
  }

  static const GymboardSession idle = GymboardSession(phase: 'idle');
}

// ── Firestore's typed JSON ──────────────────────────────────────────────
//
// Every value arrives wrapped in its type: {"integerValue":"42"}. These
// unwrap it. Anything unrecognised comes back null rather than throwing,
// because a board that gains a field should not break this app.

dynamic _unwrap(dynamic v) {
  if (v is! Map) return null;
  if (v.containsKey('stringValue')) return v['stringValue'];
  if (v.containsKey('integerValue')) {
    return int.tryParse('${v['integerValue']}');
  }
  if (v.containsKey('doubleValue')) {
    return (v['doubleValue'] as num?)?.toDouble();
  }
  if (v.containsKey('booleanValue')) return v['booleanValue'];
  if (v.containsKey('nullValue')) return null;
  if (v.containsKey('timestampValue')) {
    return DateTime.tryParse('${v['timestampValue']}');
  }
  if (v.containsKey('arrayValue')) {
    final List<dynamic> vals =
        (v['arrayValue']?['values'] as List<dynamic>?) ?? <dynamic>[];
    return vals.map(_unwrap).toList();
  }
  if (v.containsKey('mapValue')) {
    final Map<String, dynamic> f =
        ((v['mapValue']?['fields']) as Map<String, dynamic>?) ??
            <String, dynamic>{};
    return f.map((String k, dynamic val) =>
        MapEntry<String, dynamic>(k, _unwrap(val)));
  }
  return null;
}

Map<String, dynamic> _fields(Map<String, dynamic> doc) {
  final Map<String, dynamic> f =
      (doc['fields'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  return f.map(
      (String k, dynamic v) => MapEntry<String, dynamic>(k, _unwrap(v)));
}

// ── auth ────────────────────────────────────────────────────────────────
//
// The published rules allow any signed in caller, so an anonymous token is
// enough. It is cached for the life of the process: minting one per read
// would leave a trail of throwaway accounts in the project.

String? _token;
DateTime _tokenExpires = DateTime.fromMillisecondsSinceEpoch(0);

Future<String?> _idToken() async {
  if (_token != null && DateTime.now().isBefore(_tokenExpires)) return _token;
  try {
    final http.Response r = await http
        .post(
          Uri.parse(
              'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$_apiKey'),
          headers: <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, dynamic>{'returnSecureToken': true}),
        )
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) return null;
    final Map<String, dynamic> j =
        jsonDecode(r.body) as Map<String, dynamic>;
    _token = j['idToken'] as String?;
    final int secs = int.tryParse('${j['expiresIn'] ?? 3600}') ?? 3600;
    // A minute of slack so a read never starts on a token about to die.
    _tokenExpires = DateTime.now().add(Duration(seconds: secs - 60));
    return _token;
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> _getDoc(String name) async {
  final String? tok = await _idToken();
  if (tok == null) return null;
  try {
    final http.Response r = await http.get(
      Uri.parse('$_docBase/$name'),
      headers: <String, String>{'Authorization': 'Bearer $tok'},
    ).timeout(const Duration(seconds: 12));
    // 404 is not a failure. It means nothing has been recorded yet.
    if (r.statusCode == 404) return <String, dynamic>{};
    if (r.statusCode != 200) return null;
    return _fields(jsonDecode(r.body) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

// ── the two reads ───────────────────────────────────────────────────────

/// Every finished workout, oldest first. Null means the read failed, which
/// is different from an empty list meaning none have been done.
Future<List<GymboardWorkout>?> fetchGymboardHistory() async {
  final Map<String, dynamic>? f = await _getDoc('history');
  if (f == null) return null;

  final List<dynamic> done = (f['done'] as List<dynamic>?) ?? <dynamic>[];
  final List<GymboardWorkout> out = <GymboardWorkout>[];
  for (final dynamic d in done) {
    if (d is! Map) continue;
    final int at = (d['at'] as num?)?.toInt() ?? 0;
    if (at <= 0) continue;
    out.add(GymboardWorkout(
      routineId: '${d['routineId'] ?? ''}',
      at: DateTime.fromMillisecondsSinceEpoch(at),
      ms: (d['ms'] as num?)?.toInt() ?? 0,
      reps: (d['reps'] as num?)?.toInt() ?? 0,
      name: d['name'] as String?,
    ));
  }
  out.sort((GymboardWorkout a, GymboardWorkout b) => a.at.compareTo(b.at));
  return out;
}

/// What the TV is showing right now.
Future<GymboardSession?> fetchGymboardSession() async {
  final Map<String, dynamic>? f = await _getDoc('session');
  if (f == null) return null;
  if (f.isEmpty) return GymboardSession.idle;

  final int started = (f['startedAt'] as num?)?.toInt() ?? 0;
  final int restEnds = (f['restEndsAt'] as num?)?.toInt() ?? 0;
  return GymboardSession(
    phase: '${f['phase'] ?? 'idle'}',
    routineId: f['routineId'] as String?,
    startedAt: started > 0
        ? DateTime.fromMillisecondsSinceEpoch(started)
        : null,
    circuit: (f['circuit'] as num?)?.toInt() ?? 0,
    nextCircuit: (f['nextCircuit'] as num?)?.toInt() ?? 0,
    restEndsAt:
        restEnds > 0 ? DateTime.fromMillisecondsSinceEpoch(restEnds) : null,
  );
}

// ── what the rest of the app asks of it ─────────────────────────────────

/// Workout kcal per day, the shape the campaign and the dashboard want.
Map<String, double> gymKcalByDate(List<GymboardWorkout> w) {
  final Map<String, double> out = <String, double>{};
  for (final GymboardWorkout x in w) {
    out[x.date] = (out[x.date] ?? 0) + x.estimatedKcal;
  }
  return out;
}

/// Consecutive days ending today or yesterday that have a workout. A streak
/// survives one rest day, the way the goals ladder already forgives one.
int gymStreak(List<GymboardWorkout> w, {DateTime? asOf}) {
  if (w.isEmpty) return 0;
  final DateTime now = asOf ?? DateTime.now();
  final Set<String> days = w.map((GymboardWorkout x) => x.date).toSet();
  String key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  DateTime cursor = DateTime(now.year, now.month, now.day);
  if (!days.contains(key(cursor))) {
    cursor = cursor.subtract(const Duration(days: 1));
    if (!days.contains(key(cursor))) return 0;
  }
  int n = 0;
  while (days.contains(key(cursor))) {
    n++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return n;
}
