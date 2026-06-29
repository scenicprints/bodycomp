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
      'You are the coach inside BodyComp, a body-recomposition app. You receive a '
      'digest of the user\'s real data (weight, body-fat, calories eaten, macros, '
      'micronutrients, and targets). Coach them using ONLY that data.\n\n'
      'Tone is adaptive: warm and encouraging when they\'re on track, direct and '
      'tough-love when they\'re slipping — but always grounded in the specific '
      'numbers, never generic. Cite the actual figures.\n\n'
      'Cover what matters: calorie and macro adherence (especially protein and '
      'fiber), whether the scale is moving like their calorie deficit predicts, and '
      'notable micronutrient gaps versus typical adult RDAs. Only call out a '
      'food→weight pattern if the data clearly supports it — do not speculate or '
      'invent correlations. Be specific and end with one concrete next action.\n\n'
      'Output ONLY the coaching message — no preamble, no "Here is", no headings '
      'unless natural, and no explanation of your reasoning.';

  static const String _daily =
      '$_common\n\nThis is a DAILY check-in: keep it short (3–6 sentences or a few '
      'tight bullets) and focused on today and the last few days.';

  static const String _weekly =
      '$_common\n\nThis is a WEEKLY review: a few short paragraphs covering the '
      'week\'s trends, week-over-week change, any confirmed patterns, the biggest '
      'win and biggest miss, and 1–2 focus areas for next week.';

  static String systemFor(String kind) => kind == 'weekly' ? _weekly : _daily;

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
