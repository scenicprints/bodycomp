import 'dart:convert';
import 'package:http/http.dart' as http;

import 'food.dart';

// ═══════════════════════════════════════════════════════════════════════
// MY FOODS — a personal, reusable food database.
//
// Every food entered by hand or read off a Nutrition Facts label is saved
// here as a reusable template, so it can be logged again later without
// re-typing or re-calculating the macros. The store syncs to a PRIVATE
// GitHub repo (scenicprints/bodycomp-data → custom_foods.json) so the list
// follows the user across devices and survives app reinstalls.
//
// Unlike a barcode FoodTemplate (which is per-100 g), a CustomFood is stored
// PER SERVING — the same way the manual editor and a US nutrition label think
// about food — so re-logging needs zero gram math: pick the food, choose how
// many servings, done.
// ═══════════════════════════════════════════════════════════════════════

class CustomFood {
  final String id; // stable id (creation timestamp, microseconds)
  final String name;
  final String serving; // label for ONE serving, e.g. "1 bar" or "2/3 cup"
  final double? servingGrams; // grams in one serving, if known (from a label)
  final double calories; // per ONE serving
  final double protein;
  final double fat;
  final double carbs;
  final Map<String, double> nutrients; // per serving, registry keys
  final String source; // 'label' | 'manual'
  final String? barcode;
  final int updatedAtMs; // last edit — drives last-write-wins sync merge
  final bool deleted; // tombstone so a delete propagates to other devices

  CustomFood({
    required this.id,
    required this.name,
    required this.serving,
    this.servingGrams,
    required this.calories,
    required this.protein,
    required this.fat,
    required this.carbs,
    Map<String, double>? nutrients,
    this.source = 'manual',
    this.barcode,
    required this.updatedAtMs,
    this.deleted = false,
  }) : nutrients = nutrients ?? <String, double>{};

  CustomFood copyWith({
    String? name,
    String? serving,
    double? servingGrams,
    double? calories,
    double? protein,
    double? fat,
    double? carbs,
    Map<String, double>? nutrients,
    String? source,
    String? barcode,
    int? updatedAtMs,
    bool? deleted,
  }) =>
      CustomFood(
        id: id,
        name: name ?? this.name,
        serving: serving ?? this.serving,
        servingGrams: servingGrams ?? this.servingGrams,
        calories: calories ?? this.calories,
        protein: protein ?? this.protein,
        fat: fat ?? this.fat,
        carbs: carbs ?? this.carbs,
        nutrients: nutrients ?? Map<String, double>.from(this.nutrients),
        source: source ?? this.source,
        barcode: barcode ?? this.barcode,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        deleted: deleted ?? this.deleted,
      );

  /// Build a loggable entry for [quantity] servings on [date].
  FoodEntry toEntry({
    required String id,
    required String date,
    required double quantity,
    String time = '',
  }) {
    final String qtyLabel = quantity == 1
        ? serving
        : '${_fmt(quantity)} × $serving';
    return FoodEntry(
      id: id,
      date: date,
      time: time,
      name: name,
      serving: qtyLabel,
      calories: calories * quantity,
      protein: protein * quantity,
      fat: fat * quantity,
      carbs: carbs * quantity,
      nutrients: nutrients.map(
          (String k, double v) => MapEntry<String, double>(k, v * quantity)),
      source: source,
      barcode: barcode,
    );
  }

  static String _fmt(double v) {
    if (v == v.roundToDouble()) {
      return v.toInt().toString();
    }
    return v
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'serving': serving,
        if (servingGrams != null) 'servingGrams': servingGrams,
        'calories': calories,
        'protein': protein,
        'fat': fat,
        'carbs': carbs,
        if (nutrients.isNotEmpty) 'nutrients': nutrients,
        'source': source,
        if (barcode != null) 'barcode': barcode,
        'updatedAtMs': updatedAtMs,
        if (deleted) 'deleted': true,
      };

  factory CustomFood.fromJson(Map<String, dynamic> j) {
    final Map<String, double> n = <String, double>{};
    final dynamic raw = j['nutrients'];
    if (raw is Map) {
      raw.forEach((dynamic k, dynamic v) {
        if (v is num) {
          n[k as String] = v.toDouble();
        }
      });
    }
    return CustomFood(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      serving: (j['serving'] as String?) ?? '1 serving',
      servingGrams: (j['servingGrams'] as num?)?.toDouble(),
      calories: (j['calories'] as num?)?.toDouble() ?? 0,
      protein: (j['protein'] as num?)?.toDouble() ?? 0,
      fat: (j['fat'] as num?)?.toDouble() ?? 0,
      carbs: (j['carbs'] as num?)?.toDouble() ?? 0,
      nutrients: n,
      source: (j['source'] as String?) ?? 'manual',
      barcode: j['barcode'] as String?,
      updatedAtMs: (j['updatedAtMs'] as num?)?.toInt() ?? 0,
      deleted: j['deleted'] == true,
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// LABEL PARSER — pure. Reads OCR text off a Nutrition Facts panel and pulls
// the per-serving numbers. Tolerant of OCR noise, merged lines, and missing
// fields; whatever it can't find comes back null so the editor leaves it
// blank for the user to fill. US labels are per serving, which matches the
// CustomFood model exactly.
// ───────────────────────────────────────────────────────────────────────

class LabelParse {
  final String? servingRaw; // e.g. "2/3 cup (55g)"
  final double? servingGrams;
  final double? calories;
  final double? protein;
  final double? fat;
  final double? carbs;
  final double? fiber;
  final double? sugars;
  final double? sodium; // mg
  const LabelParse({
    this.servingRaw,
    this.servingGrams,
    this.calories,
    this.protein,
    this.fat,
    this.carbs,
    this.fiber,
    this.sugars,
    this.sodium,
  });

  /// True if we found at least the calories — enough to be worth pre-filling.
  bool get hasAnything =>
      calories != null ||
      protein != null ||
      fat != null ||
      carbs != null;
}

LabelParse parseNutritionLabel(String ocrText) {
  // Normalise: lower-case, collapse whitespace, fix the common OCR slips where
  // a unit's letter swallows a digit. We keep it simple and forgiving.
  final String t = ocrText.toLowerCase().replaceAll(RegExp(r'[ \t]+'), ' ');

  double? num1(RegExp re) {
    final Match? m = re.firstMatch(t);
    if (m == null) {
      return null;
    }
    return double.tryParse(m.group(1)!);
  }

  // Calories: a standalone "Calories 230" — explicitly NOT "calories from fat".
  final double? calories =
      num1(RegExp(r'calories(?!\s*from)\s*[:\-]?\s*(\d{1,4})'));

  // Macros are "<keyword> <number> g". "total" prefixes are optional because
  // OCR often drops them.
  final double? fat =
      num1(RegExp(r'(?:total\s*)?fat\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g'));
  final double? carbs = num1(
      RegExp(r'(?:total\s*)?carbo?hydrate?s?\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g'));
  final double? protein =
      num1(RegExp(r'protein\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g'));
  final double? fiber = num1(
      RegExp(r'(?:dietary\s*)?fib(?:er|re)\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g'));
  final double? sugars = num1(
      RegExp(r'(?:total\s*|includes\s*)?sugars?\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g'));
  final double? sodium =
      num1(RegExp(r'sodium\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*mg'));

  // Serving size + grams. Prefer the grams inside parentheses next to
  // "serving size"; fall back to a bare "serving size 30 g".
  String? servingRaw;
  double? servingGrams;
  final Match? ss = RegExp(
          r'serving size\s*[:\-]?\s*([^\n]*?)(?:\r|\n|servings per|amount per|calories|$)')
      .firstMatch(t);
  if (ss != null) {
    final String raw = ss.group(1)!.trim();
    if (raw.isNotEmpty) {
      servingRaw = raw;
    }
  }
  final Match? sg =
      RegExp(r'serving size[^\n]*?\((\d+(?:\.\d+)?)\s*g\)').firstMatch(t);
  if (sg != null) {
    servingGrams = double.tryParse(sg.group(1)!);
  } else {
    final Match? sg2 =
        RegExp(r'serving size\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*g\b').firstMatch(t);
    if (sg2 != null) {
      servingGrams = double.tryParse(sg2.group(1)!);
    }
  }

  return LabelParse(
    servingRaw: servingRaw,
    servingGrams: servingGrams,
    calories: calories,
    protein: protein,
    fat: fat,
    carbs: carbs,
    fiber: fiber,
    sugars: sugars,
    sodium: sodium,
  );
}

// ═══════════════════════════════════════════════════════════════════════
// SYNC STORE — reads/writes custom_foods.json in the private data repo via
// the GitHub Contents API. The token is injected at build time and scoped to
// ONLY this private repo, so a cracked APK can at worst touch this one food
// list (see [[bodycomp-myfoods-sync]] memory).
//
// Networking lives here; the pure merge + encode/decode are unit-tested.
// ═══════════════════════════════════════════════════════════════════════

const String kDataRepoOwner = 'scenicprints';
const String kDataRepoName = 'bodycomp-data';
const String kCustomFoodsPath = 'custom_foods.json';

class RemoteFoods {
  final List<CustomFood> foods;
  final String? sha; // blob sha needed to update the file
  const RemoteFoods(this.foods, this.sha);
}

class CustomFoodStore {
  static String get _token =>
      const String.fromEnvironment('GITHUB_DATA_TOKEN');

  /// Whether a sync token was baked into this build.
  static bool get isConfigured => _token.isNotEmpty;

  static Uri get _contentsUri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kCustomFoodsPath');

  static Map<String, String> get _headers => <String, String>{
        'Authorization': 'Bearer $_token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'BodyComp (github.com/scenicprints/bodycomp)',
      };

  /// Last-write-wins merge keyed by id. Newer `updatedAtMs` wins; ties keep
  /// the incoming copy. Tombstones (deleted) are preserved so deletions
  /// propagate. Output is name-sorted with tombstones last.
  static List<CustomFood> mergeFoods(
      List<CustomFood> a, List<CustomFood> b) {
    final Map<String, CustomFood> m = <String, CustomFood>{};
    for (final CustomFood f in <CustomFood>[...a, ...b]) {
      final CustomFood? cur = m[f.id];
      if (cur == null || f.updatedAtMs >= cur.updatedAtMs) {
        m[f.id] = f;
      }
    }
    final List<CustomFood> out = m.values.toList();
    out.sort((CustomFood x, CustomFood y) {
      if (x.deleted != y.deleted) {
        return x.deleted ? 1 : -1;
      }
      return x.name.toLowerCase().compareTo(y.name.toLowerCase());
    });
    return out;
  }

  /// Decode the on-disk/remote file format → list of foods.
  static List<CustomFood> decodeFile(String jsonStr) {
    try {
      final dynamic d = jsonDecode(jsonStr);
      final dynamic list = (d is Map) ? d['foods'] : d;
      if (list is List) {
        return list
            .whereType<Map<String, dynamic>>()
            .map(CustomFood.fromJson)
            .toList();
      }
    } catch (_) {}
    return <CustomFood>[];
  }

  /// Encode foods → the file format (pretty-printed for a readable diff).
  static String encodeFile(List<CustomFood> foods) {
    const JsonEncoder enc = JsonEncoder.withIndent('  ');
    return enc.convert(<String, dynamic>{
      'version': 1,
      'foods': foods.map((CustomFood f) => f.toJson()).toList(),
    });
  }

  /// Fetch the remote file. Returns null on any failure (offline, auth, etc.)
  /// so callers can fall back to the local cache.
  static Future<RemoteFoods?> fetchRemote() async {
    if (!isConfigured) {
      return null;
    }
    try {
      final http.Response r = await http
          .get(_contentsUri, headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        // File not created yet — treat as empty, no sha.
        return const RemoteFoods(<CustomFood>[], null);
      }
      if (r.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> j =
          jsonDecode(r.body) as Map<String, dynamic>;
      final String content =
          (j['content'] as String? ?? '').replaceAll('\n', '');
      final String? sha = j['sha'] as String?;
      final String decoded =
          content.isEmpty ? '' : utf8.decode(base64.decode(content));
      return RemoteFoods(decodeFile(decoded), sha);
    } catch (_) {
      return null;
    }
  }

  /// Write [foods] to the remote file. Returns the new blob sha on success,
  /// or null on failure. Pass the [sha] from the last fetch to update; null
  /// creates the file.
  static Future<String?> pushRemote(
      List<CustomFood> foods, String? sha) async {
    if (!isConfigured) {
      return null;
    }
    try {
      final String content =
          base64.encode(utf8.encode(encodeFile(foods)));
      final Map<String, dynamic> body = <String, dynamic>{
        'message': 'Update custom foods',
        'content': content,
        'branch': 'main',
        if (sha != null) 'sha': sha,
      };
      final http.Response r = await http
          .put(_contentsUri, headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 || r.statusCode == 201) {
        final Map<String, dynamic> j =
            jsonDecode(r.body) as Map<String, dynamic>;
        final Map<String, dynamic>? c =
            j['content'] as Map<String, dynamic>?;
        return c?['sha'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
