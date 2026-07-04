import 'dart:convert';
import 'package:http/http.dart' as http;

// ═══════════════════════════════════════════════════════════════════════
// FOOD ADVISOR — AI coaching via the Claude API
//
// Hybrid design: the app computes the facts (see AdvisorDigest in main.dart)
// and Claude turns them into coaching. The API key is baked in at build time
// (GitHub secret → --dart-define). The model is chosen in Settings.
// ═══════════════════════════════════════════════════════════════════════

class AdvisorModel {
  final String id;
  final String label;
  final String cost;
  const AdvisorModel(this.id, this.label, this.cost);
}

const String kDefaultAdvisorModel = 'claude-opus-4-8';

const List<AdvisorModel> kAdvisorModels = <AdvisorModel>[
  AdvisorModel('claude-haiku-4-5', 'Haiku — cheapest', '~\$1–2/mo'),
  AdvisorModel('claude-sonnet-4-6', 'Sonnet — balanced', '~\$3–6/mo'),
  AdvisorModel('claude-opus-4-8', 'Opus — best', '~\$6–10/mo'),
];

String advisorModelLabel(String id) {
  for (final AdvisorModel m in kAdvisorModels) {
    if (m.id == id) {
      return m.label;
    }
  }
  return id;
}

class AdvisorInsight {
  final String kind; // 'daily' | 'weekly'
  final String periodKey; // 'YYYY-MM-DD' (daily) or week-start date (weekly)
  final String text;
  final int createdAtMs;
  AdvisorInsight(
      {required this.kind,
      required this.periodKey,
      required this.text,
      required this.createdAtMs});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'periodKey': periodKey,
        'text': text,
        'createdAtMs': createdAtMs,
      };
  factory AdvisorInsight.fromJson(Map<String, dynamic> j) => AdvisorInsight(
        kind: j['kind'] as String,
        periodKey: j['periodKey'] as String,
        text: j['text'] as String,
        createdAtMs: (j['createdAtMs'] as num?)?.toInt() ?? 0,
      );
}

class AdvisorException implements Exception {
  final String message;
  AdvisorException(this.message);
  @override
  String toString() => message;
}

class Advisor {
  /// Baked in at build via --dart-define=ANTHROPIC_API_KEY=...
  static String get apiKey =>
      const String.fromEnvironment('ANTHROPIC_API_KEY');
  static bool get configured => apiKey.isNotEmpty;

  // Adaptive tone, data-grounded, confident-only patterns, full coverage,
  // final-answer-only (so Opus 4.8 with thinking off doesn't narrate).
  static const String _common =
      'You are the coach inside BodyComp, a body-recomposition app. Find the few '
      'things in this user\'s real data that actually matter and say them straight. '
      'You receive a PER-DAY log: every food eaten (by name), '
      'calories/protein/fat/carbs/fiber/sugar, sleep hours + vitals, whether they '
      'ran and how it went, weigh-ins (weight, body-fat %, lean mass), lean-mass '
      'and fat-mass trends, and their targets.\n\n'
      'RULES:\n'
      '- Reason from THEIR numbers and end every point in a consequence — the "so '
      'what". Never recite a target without tying it to their body and what it '
      'does to them (e.g. lean mass ~150 lb → ~150 g protein holds muscle on a '
      'cut; at 80 g they are shedding muscle, so the scale drops but as muscle — '
      'recomp going backwards).\n'
      '- OUTCOMES BEAT TARGETS. Judge by what is actually happening to their body. '
      'If lean mass is holding or rising, whatever they are doing is working — '
      'praise it, do NOT police the input. Only flag an input (protein, sugar, '
      'sleep) when the OUTCOME shows it is hurting them.\n'
      '- HUNT FOR PATTERNS across food, sleep, training and results: recurring '
      'nutrient gaps, specific foods worth cutting or keeping (name them), '
      'behaviours that track with staying on plan, and cross-domain links '
      '(sleep ↔ runs ↔ adherence ↔ body-fat). Assert a pattern ONLY if it repeats '
      'across enough days; call a thin hunch out as "worth watching", never as '
      'fact. Day-to-day body-fat and weight are mostly water and measurement '
      'noise — never build a claim on a single day.\n'
      '- Be honest, not encouraging-by-default. If they are slipping, say so '
      'plainly. No hedging ("maybe/either/or"), no generic advice, and NEVER tell '
      'them to "log more" or comment on how much they have logged.\n'
      '- TRUST THE LOGGED NUMBERS. Treat every logged day as accurate. NEVER '
      'suggest — outright or by implication — that they are mis-logging, '
      'under-reporting, forgetting to log, sneaking untracked food, or "not doing '
      'it right". That accusation is off-limits. When the logged intake and the '
      'scale disagree (a deficit that isn\'t showing up as loss, or vice-versa), '
      'the explanation is a TDEE estimate that\'s off, water weight, or plain '
      'measurement noise — say THAT, not that the user is the problem.\n'
      '- UNLOGGED DAYS ARE NOT FAILURES. A day marked "no food logged" is simply a '
      'day with no data — skip it, do not count it against them, do not treat gaps '
      'as the reason progress stalled, and never scold them for it. Judge only the '
      'days they actually logged.\n'
      '- A DEFICIT IS ONLY REAL FOR DAYS THEY LOGGED. Calorie and deficit figures '
      'describe the logged days ONLY — they say nothing about a stretch the user '
      'has not tracked. If the digest flags intake as untracked or the last food '
      'log as stale, you do NOT know what they are eating now: NEVER tell them they '
      'are "on a deficit", "on track", or to "not worry" based on older logs. When '
      'the scale is rising and current intake is untracked, they are eating at a '
      'surplus right now — say that plainly, and note the numbers will confirm it '
      'once they start tracking again.\n'
      '- Cite the actual figures and food names. Be specific.\n\n'
      'Output ONLY the coaching message — no preamble, no "Here is", no narration '
      'of your reasoning.';

  static const String _daily =
      '$_common\n\nThis is a DAILY check-in: focus on the last few days. Lead with '
      'the single most important thing right now, then at most 2–3 sharp, specific '
      'points. Keep it short.';

  static const String _weekly =
      '$_common\n\nThis is a WEEKLY review: sweep the whole period for patterns and '
      'correlations across food, sleep, training and body-composition change. '
      'Surface the biggest win, the biggest leak, any repeating pattern worth '
      'acting on, and the one change that would move the needle most next week.';

  static const String _run =
      'You are the running coach inside BodyComp. Coach this run like a real, '
      'honest coach — lead with the run itself, be realistic, not a cheerleader.\n\n'
      'You receive: the run (duration, distance, pace, average heart rate), the '
      'user\'s OWN heart-rate references (resting HR, and their HR during the '
      'warm-up walk), recent run history, their 5K plan level, and light '
      'body-comp/sleep context.\n\n'
      'RULES:\n'
      '- Judge effort from THEIR OWN heart rate, not textbook zones: compare the '
      'run\'s average HR to their resting HR and their warm-up-walk HR. A run only '
      'a little above their walking HR is easy; one far above it is hard. Say '
      'plainly whether this run was controlled, solid, or a grind, and back it '
      'with the numbers.\n'
      '- Give real running insight: what the pace + HR say about their aerobic '
      'fitness and whether they should move up, hold, or drop a level. Be direct.\n'
      '- Touch sleep/fuel ONLY when it is clearly affecting the run (e.g. HR '
      'higher than usual after a short-sleep night on a deficit) — one line, tied '
      'to the run.\n'
      '- Honest and specific, cite the numbers. No empty positivity, no hedging.\n\n'
      'Keep it tight (3–6 sentences or a few bullets). Output ONLY the coaching '
      'message.';

  static String systemFor(String kind) {
    if (kind == 'weekly') {
      return _weekly;
    }
    if (kind == 'run') {
      return _run;
    }
    return _daily;
  }

  /// Calls the Claude Messages API and returns the coaching text.
  static Future<String> generate({
    required String model,
    required String kind,
    required String digest,
    int maxTokens = 1024,
  }) async {
    if (!configured) {
      throw AdvisorException('No API key configured in this build.');
    }
    final http.Response resp = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: <String, String>{
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'model': model,
        'max_tokens': maxTokens,
        'system': systemFor(kind),
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': digest},
        ],
      }),
    );
    if (resp.statusCode != 200) {
      throw AdvisorException(_errorFor(resp.statusCode));
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['stop_reason'] == 'refusal') {
      throw AdvisorException('The model declined to respond to this request.');
    }
    final List<dynamic> content =
        (data['content'] as List<dynamic>?) ?? <dynamic>[];
    final StringBuffer buf = StringBuffer();
    for (final dynamic b in content) {
      final Map<String, dynamic> m = b as Map<String, dynamic>;
      if (m['type'] == 'text') {
        buf.write(m['text'] as String? ?? '');
      }
    }
    final String text = buf.toString().trim();
    if (text.isEmpty) {
      throw AdvisorException('The model returned an empty response.');
    }
    return text;
  }

  static String _errorFor(int code) {
    switch (code) {
      case 401:
        return 'API key was rejected (401). Check the key baked into this build.';
      case 403:
        return 'API key lacks access (403) — check billing/credits.';
      case 429:
        return 'Rate limited (429) — wait a moment and try again.';
      case 400:
        return 'Request rejected (400).';
      default:
        return code >= 500
            ? 'Anthropic server error ($code) — try again shortly.'
            : 'Request failed ($code).';
    }
  }
}
