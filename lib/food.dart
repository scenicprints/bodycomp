import 'dart:convert';
import 'package:http/http.dart' as http;

// ═══════════════════════════════════════════════════════════════════════
// FOOD JOURNAL — data model, nutrient registry, Open Food Facts client
//
// Calories + the three macros are first-class fields (the TDEE math and the
// rings depend on them). Everything else — fiber, sugars, sodium, vitamins,
// minerals — lives in a flexible `nutrients` map keyed by the registry below,
// so we can capture whatever a barcode/label provides without schema changes.
// ═══════════════════════════════════════════════════════════════════════

/// One trackable micronutrient and how to read it from Open Food Facts.
class Nutrient {
  final String key; // stable id used in the nutrients map + JSON
  final String label; // shown in the UI
  final String unit; // display unit
  final double fromGrams; // multiply OFF's gram value to get the display unit
  final String offField; // Open Food Facts field stem (…_100g)
  const Nutrient(this.key, this.label, this.unit, this.fromGrams, this.offField);
}

// Order here is the display order. Label-standard nutrients first, then the
// "extended when available" set.
const List<Nutrient> kNutrients = <Nutrient>[
  Nutrient('fiber', 'Fiber', 'g', 1, 'fiber'),
  Nutrient('sugars', 'Sugars', 'g', 1, 'sugars'),
  Nutrient('saturatedFat', 'Saturated Fat', 'g', 1, 'saturated-fat'),
  Nutrient('sodium', 'Sodium', 'mg', 1000, 'sodium'),
  Nutrient('cholesterol', 'Cholesterol', 'mg', 1000, 'cholesterol'),
  Nutrient('potassium', 'Potassium', 'mg', 1000, 'potassium'),
  Nutrient('calcium', 'Calcium', 'mg', 1000, 'calcium'),
  Nutrient('iron', 'Iron', 'mg', 1000, 'iron'),
  Nutrient('vitaminD', 'Vitamin D', 'µg', 1000000, 'vitamin-d'),
  // Extended — usually blank on packaged foods, captured when present.
  Nutrient('vitaminA', 'Vitamin A', 'µg', 1000000, 'vitamin-a'),
  Nutrient('vitaminC', 'Vitamin C', 'mg', 1000, 'vitamin-c'),
  Nutrient('vitaminE', 'Vitamin E', 'mg', 1000, 'vitamin-e'),
  Nutrient('vitaminB6', 'Vitamin B6', 'mg', 1000, 'vitamin-b6'),
  Nutrient('vitaminB12', 'Vitamin B12', 'µg', 1000000, 'vitamin-b12'),
  Nutrient('folate', 'Folate', 'µg', 1000000, 'folates'),
  Nutrient('magnesium', 'Magnesium', 'mg', 1000, 'magnesium'),
  Nutrient('zinc', 'Zinc', 'mg', 1000, 'zinc'),
];

Nutrient? nutrientByKey(String key) {
  for (final Nutrient n in kNutrients) {
    if (n.key == key) {
      return n;
    }
  }
  return null;
}

// ───────────────────────────────────────────────────────────────────────
// A logged food item.
// ───────────────────────────────────────────────────────────────────────
class FoodEntry {
  final String id;
  final String date; // 'YYYY-MM-DD'
  final String time; // 'HH:mm' (empty if unknown) — used for meal grouping
  final String name;
  final String serving; // human description, e.g. "73 g" or "1 cup"
  final double calories;
  final double protein;
  final double fat;
  final double carbs;
  final Map<String, double> nutrients; // display-unit values, registry keys
  final String source; // 'barcode' | 'label' | 'manual'
  final String? barcode;
  // Grams this logged amount represents, when known — lets the editor
  // re-scale every macro by weight instead of making the user redo the math.
  // Null for servings-based / legacy entries (editor falls back to a ×amount).
  final double? baseGrams;

  FoodEntry({
    required this.id,
    required this.date,
    this.time = '',
    required this.name,
    required this.serving,
    required this.calories,
    required this.protein,
    required this.fat,
    required this.carbs,
    Map<String, double>? nutrients,
    this.source = 'manual',
    this.barcode,
    this.baseGrams,
  }) : nutrients = nutrients ?? <String, double>{};

  /// Meal section from the time of day (falls back to "Other").
  String get mealPeriod {
    if (time.length < 2) {
      return 'Other';
    }
    final int h = int.tryParse(time.split(':').first) ?? -1;
    if (h < 0) {
      return 'Other';
    }
    if (h < 11) {
      return 'Breakfast';
    }
    if (h < 15) {
      return 'Lunch';
    }
    if (h < 21) {
      return 'Dinner';
    }
    return 'Snacks';
  }

  FoodEntry copyWith({String? id, String? date, String? time}) => FoodEntry(
        id: id ?? this.id,
        date: date ?? this.date,
        time: time ?? this.time,
        name: name,
        serving: serving,
        calories: calories,
        protein: protein,
        fat: fat,
        carbs: carbs,
        nutrients: Map<String, double>.from(nutrients),
        source: source,
        barcode: barcode,
        baseGrams: baseGrams,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'date': date,
        if (time.isNotEmpty) 'time': time,
        'name': name,
        'serving': serving,
        'calories': calories,
        'protein': protein,
        'fat': fat,
        'carbs': carbs,
        'nutrients': nutrients,
        'source': source,
        if (barcode != null) 'barcode': barcode,
        if (baseGrams != null) 'baseGrams': baseGrams,
      };

  factory FoodEntry.fromJson(Map<String, dynamic> j) {
    final Map<String, double> n = <String, double>{};
    final dynamic raw = j['nutrients'];
    if (raw is Map) {
      raw.forEach((dynamic k, dynamic v) {
        if (v is num) {
          n[k as String] = v.toDouble();
        }
      });
    }
    return FoodEntry(
      id: j['id'] as String,
      date: j['date'] as String,
      time: (j['time'] as String?) ?? '',
      name: j['name'] as String,
      serving: (j['serving'] as String?) ?? '',
      calories: (j['calories'] as num).toDouble(),
      protein: (j['protein'] as num?)?.toDouble() ?? 0,
      fat: (j['fat'] as num?)?.toDouble() ?? 0,
      carbs: (j['carbs'] as num?)?.toDouble() ?? 0,
      nutrients: n,
      source: (j['source'] as String?) ?? 'manual',
      barcode: j['barcode'] as String?,
      baseGrams: (j['baseGrams'] as num?)?.toDouble(),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────
// Per-day rollups.
// ───────────────────────────────────────────────────────────────────────
class DayTotals {
  final double calories;
  final double protein;
  final double fat;
  final double carbs;
  final Map<String, double> nutrients;
  const DayTotals(
      this.calories, this.protein, this.fat, this.carbs, this.nutrients);
}

class FoodMath {
  static List<FoodEntry> forDate(List<FoodEntry> foods, String date) =>
      foods.where((FoodEntry f) => f.date == date).toList();

  static DayTotals totals(List<FoodEntry> foods, String date) {
    double cal = 0, p = 0, f = 0, c = 0;
    final Map<String, double> n = <String, double>{};
    for (final FoodEntry e in forDate(foods, date)) {
      cal += e.calories;
      p += e.protein;
      f += e.fat;
      c += e.carbs;
      e.nutrients.forEach((String k, double v) {
        n[k] = (n[k] ?? 0) + v;
      });
    }
    return DayTotals(cal, p, f, c, n);
  }

  /// Total calories logged per date, for days that have any food entries.
  /// This is what feeds the adaptive TDEE on scanned days.
  static Map<String, double> caloriesByDate(List<FoodEntry> foods) {
    final Map<String, double> m = <String, double>{};
    for (final FoodEntry e in foods) {
      m[e.date] = (m[e.date] ?? 0) + e.calories;
    }
    return m;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// OPEN FOOD FACTS
// ═══════════════════════════════════════════════════════════════════════

/// Per-100g nutrition pulled from a barcode, before the user picks a serving.
class FoodTemplate {
  final String name;
  final double kcal100;
  final double protein100;
  final double fat100;
  final double carbs100;
  final Map<String, double> nutrients100; // display units, per 100 g
  final double? servingGrams; // parsed default serving, if any
  final String? servingSizeRaw;
  final String? barcode;

  FoodTemplate({
    required this.name,
    required this.kcal100,
    required this.protein100,
    required this.fat100,
    required this.carbs100,
    required this.nutrients100,
    this.servingGrams,
    this.servingSizeRaw,
    this.barcode,
  });

  /// Scale to [grams] and produce a loggable entry.
  FoodEntry toEntry(
      {required String id,
      required String date,
      required double grams,
      String? servingLabel,
      String time = '',
      String source = 'barcode'}) {
    final double s = grams / 100.0;
    return FoodEntry(
      id: id,
      date: date,
      time: time,
      name: name,
      serving: servingLabel ?? '${_fmt(grams)} g',
      calories: kcal100 * s,
      protein: protein100 * s,
      fat: fat100 * s,
      carbs: carbs100 * s,
      nutrients: nutrients100
          .map((String k, double v) => MapEntry<String, double>(k, v * s)),
      source: source,
      barcode: barcode,
      baseGrams: grams,
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'kcal100': kcal100,
        'protein100': protein100,
        'fat100': fat100,
        'carbs100': carbs100,
        'nutrients100': nutrients100,
        if (servingGrams != null) 'servingGrams': servingGrams,
        if (barcode != null) 'barcode': barcode,
      };

  factory FoodTemplate.fromJson(Map<String, dynamic> j) {
    final Map<String, double> n = <String, double>{};
    final dynamic raw = j['nutrients100'];
    if (raw is Map) {
      raw.forEach((dynamic k, dynamic v) {
        if (v is num) {
          n[k as String] = v.toDouble();
        }
      });
    }
    return FoodTemplate(
      name: j['name'] as String,
      kcal100: (j['kcal100'] as num).toDouble(),
      protein100: (j['protein100'] as num?)?.toDouble() ?? 0,
      fat100: (j['fat100'] as num?)?.toDouble() ?? 0,
      carbs100: (j['carbs100'] as num?)?.toDouble() ?? 0,
      nutrients100: n,
      servingGrams: (j['servingGrams'] as num?)?.toDouble(),
      barcode: j['barcode'] as String?,
    );
  }
}

class OpenFoodFacts {
  /// Looks up a barcode. Returns null if not found / no usable nutrition.
  static Future<FoodTemplate?> fetchByBarcode(String barcode) async {
    final Uri uri = Uri.parse(
        'https://world.openfoodfacts.org/api/v2/product/$barcode.json'
        '?fields=product_name,brands,nutriments,serving_size,quantity');
    final http.Response resp = await http.get(uri, headers: <String, String>{
      'User-Agent': 'BodyComp/1.1 (github.com/scenicprints/bodycomp)'
    });
    if (resp.statusCode != 200) {
      return null;
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if ((data['status'] as num?)?.toInt() != 1) {
      return null;
    }
    return parseProduct(data['product'] as Map<String, dynamic>, barcode);
  }

  /// Searches by name (for foods without a barcode, e.g. "onion").
  /// Returns the foods that have usable calorie data, best matches first.
  static Future<List<FoodTemplate>> search(String query) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return <FoodTemplate>[];
    }
    final Uri uri = Uri.parse(
        'https://world.openfoodfacts.org/cgi/search.pl'
        '?search_terms=${Uri.encodeQueryComponent(q)}'
        '&search_simple=1&action=process&json=1&page_size=30'
        '&fields=product_name,brands,nutriments,serving_size,code');
    final http.Response resp = await http.get(uri, headers: <String, String>{
      'User-Agent': 'BodyComp/1.1 (github.com/scenicprints/bodycomp)'
    });
    if (resp.statusCode != 200) {
      return <FoodTemplate>[];
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final List<dynamic> products =
        (data['products'] as List<dynamic>?) ?? <dynamic>[];
    final List<FoodTemplate> out = <FoodTemplate>[];
    for (final dynamic p in products) {
      final Map<String, dynamic> m = p as Map<String, dynamic>;
      final FoodTemplate? t = parseProduct(m, m['code'] as String?);
      if (t != null) {
        out.add(t);
      }
    }
    return out;
  }

  /// Parsing is split out so it can be unit-tested without a network call.
  static FoodTemplate? parseProduct(
      Map<String, dynamic> product, String? barcode) {
    final Map<String, dynamic> nut =
        (product['nutriments'] as Map<String, dynamic>?) ??
            <String, dynamic>{};

    final double? kcal = _kcalPer100(nut);
    if (kcal == null) {
      return null; // no calorie data → not useful for a food log
    }

    String name = (product['product_name'] as String?)?.trim() ?? '';
    final String brand = (product['brands'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      name = brand.isNotEmpty ? brand : 'Unknown food';
    } else if (brand.isNotEmpty) {
      name = '$name ($brand)';
    }

    final Map<String, double> micros = <String, double>{};
    for (final Nutrient n in kNutrients) {
      final double? g = _num(nut['${n.offField}_100g']);
      if (g != null) {
        micros[n.key] = g * n.fromGrams;
      }
    }

    return FoodTemplate(
      name: name,
      kcal100: kcal,
      protein100: _num(nut['proteins_100g']) ?? 0,
      fat100: _num(nut['fat_100g']) ?? 0,
      carbs100: _num(nut['carbohydrates_100g']) ?? 0,
      nutrients100: micros,
      servingGrams: _parseGrams(product['serving_size'] as String?),
      servingSizeRaw: product['serving_size'] as String?,
      barcode: barcode,
    );
  }

  static double? _kcalPer100(Map<String, dynamic> nut) {
    final double? kcal = _num(nut['energy-kcal_100g']);
    if (kcal != null) {
      return kcal;
    }
    // Fall back to kJ → kcal.
    final double? kj = _num(nut['energy_100g']) ?? _num(nut['energy-kj_100g']);
    if (kj != null) {
      return kj / 4.184;
    }
    return null;
  }

  static double? _num(dynamic v) {
    if (v is num) {
      return v.toDouble();
    }
    if (v is String) {
      return double.tryParse(v);
    }
    return null;
  }

  /// Pulls a gram figure out of strings like "30 g", "1 cup (240 g)", "240g".
  static double? _parseGrams(String? s) {
    if (s == null) {
      return null;
    }
    final RegExpMatch? m =
        RegExp(r'(\d+(?:\.\d+)?)\s*g\b', caseSensitive: false).firstMatch(s);
    if (m != null) {
      return double.tryParse(m.group(1)!);
    }
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// USDA FOODDATA CENTRAL  (primary source — authoritative for whole foods)
//
// API key is injected at build time via --dart-define=USDA_API_KEY=...
// (stored as a GitHub secret, never in source). Falls back to the rate-
// limited DEMO_KEY so the app still works without one.
// ═══════════════════════════════════════════════════════════════════════

// USDA nutrient numbers → our registry keys (micros only; energy/macros below).
const Map<String, String> _usdaNumToKey = <String, String>{
  '291': 'fiber',
  '269': 'sugars',
  '606': 'saturatedFat',
  '307': 'sodium',
  '601': 'cholesterol',
  '306': 'potassium',
  '301': 'calcium',
  '303': 'iron',
  '328': 'vitaminD', // µg (D2 + D3)
  '320': 'vitaminA', // µg RAE
  '401': 'vitaminC',
  '323': 'vitaminE',
  '415': 'vitaminB6',
  '418': 'vitaminB12',
  '417': 'folate',
  '304': 'magnesium',
  '309': 'zinc',
};

class Usda {
  static String get apiKey {
    const String k = String.fromEnvironment('USDA_API_KEY');
    return k.isEmpty ? 'DEMO_KEY' : k;
  }

  static Future<List<FoodTemplate>> search(String query) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return <FoodTemplate>[];
    }
    // Two separate requests: generic datasets and Branded. A single mixed
    // query lets branded products fill the whole page by relevance before any
    // local ranking can run — searching "asparagus" should lead with
    // "Asparagus, cooked from fresh" (Survey/FNDDS — which the old query
    // never even requested), with brands trailing behind.
    final List<List<Map<String, dynamic>>> pages =
        await Future.wait(<Future<List<Map<String, dynamic>>>>[
      _searchPage(q, 'Foundation,SR Legacy,Survey (FNDDS)', 25),
      _searchPage(q, 'Branded', 10),
    ]);
    // Within generics: Foundation → SR Legacy → FNDDS.
    int rank(Map<String, dynamic> f) {
      switch ((f['dataType'] as String?) ?? '') {
        case 'Foundation':
          return 0;
        case 'SR Legacy':
          return 1;
        default:
          return 2; // Survey (FNDDS)
      }
    }

    final List<Map<String, dynamic>> generic = pages[0]
      ..sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
          rank(a).compareTo(rank(b)));
    final List<FoodTemplate> out = <FoodTemplate>[];
    for (final Map<String, dynamic> f in <Map<String, dynamic>>[
      ...generic,
      ...pages[1],
    ]) {
      final FoodTemplate? t = parseFood(f);
      if (t != null) {
        out.add(t);
      }
    }
    return out;
  }

  /// One foods/search page for [dataTypes]; empty on any failure so a bad
  /// branded request can't take the generic results down with it.
  static Future<List<Map<String, dynamic>>> _searchPage(
      String q, String dataTypes, int pageSize) async {
    try {
      final Uri uri = Uri.parse('https://api.nal.usda.gov/fdc/v1/foods/search'
          '?api_key=$apiKey&query=${Uri.encodeQueryComponent(q)}'
          '&pageSize=$pageSize&dataType=${Uri.encodeQueryComponent(dataTypes)}');
      final http.Response resp = await http.get(uri);
      if (resp.statusCode != 200) {
        return <Map<String, dynamic>>[];
      }
      final Map<String, dynamic> data =
          jsonDecode(resp.body) as Map<String, dynamic>;
      return ((data['foods'] as List<dynamic>?) ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<FoodTemplate?> fetchByBarcode(String barcode) async {
    final Uri uri = Uri.parse('https://api.nal.usda.gov/fdc/v1/foods/search'
        '?api_key=$apiKey&query=${Uri.encodeQueryComponent(barcode)}'
        '&dataType=Branded&pageSize=10');
    final http.Response resp = await http.get(uri);
    if (resp.statusCode != 200) {
      return null;
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final List<dynamic> foods =
        (data['foods'] as List<dynamic>?) ?? <dynamic>[];
    for (final dynamic f in foods) {
      final Map<String, dynamic> m = f as Map<String, dynamic>;
      if ((m['gtinUpc'] as String?)?.replaceAll(RegExp(r'^0+'), '') ==
          barcode.replaceAll(RegExp(r'^0+'), '')) {
        final FoodTemplate? t = parseFood(m, barcode: barcode);
        if (t != null) {
          return t;
        }
      }
    }
    return null;
  }

  /// Public for unit tests. Expects a foods/search "food" object.
  static FoodTemplate? parseFood(Map<String, dynamic> food, {String? barcode}) {
    final List<dynamic> nutrients =
        (food['foodNutrients'] as List<dynamic>?) ?? <dynamic>[];
    double? kcal;
    double prot = 0, fat = 0, carb = 0;
    final Map<String, double> micros = <String, double>{};

    for (final dynamic raw in nutrients) {
      final Map<String, dynamic> fn = raw as Map<String, dynamic>;
      final String number =
          (fn['nutrientNumber'] ?? fn['number'])?.toString() ?? '';
      final double? value = _num(fn['value'] ?? fn['amount']);
      final String unit = (fn['unitName'] ?? fn['unit'] ?? '').toString();
      if (value == null) {
        continue;
      }
      switch (number) {
        case '208':
          kcal = value;
          break;
        case '203':
          prot = value;
          break;
        case '204':
          fat = value;
          break;
        case '205':
          carb = value;
          break;
        default:
          final String? key = _usdaNumToKey[number];
          if (key != null) {
            final Nutrient? n = nutrientByKey(key);
            if (n != null) {
              final double? d = _toDisplay(value, unit, n);
              if (d != null) {
                micros[key] = d;
              }
            }
          }
      }
    }
    if (kcal == null) {
      return null;
    }

    String name = (food['description'] as String?)?.trim() ?? 'Unknown food';
    final String brand = ((food['brandName'] ?? food['brandOwner']) as String?)
            ?.trim() ??
        '';
    if (brand.isNotEmpty) {
      name = '$name ($brand)';
    }

    return FoodTemplate(
      name: name,
      kcal100: kcal,
      protein100: prot,
      fat100: fat,
      carbs100: carb,
      nutrients100: micros,
      servingGrams: _servingGrams(food),
      barcode: barcode ?? food['gtinUpc'] as String?,
    );
  }

  static double? _toDisplay(double value, String unit, Nutrient n) {
    double grams;
    switch (unit.toUpperCase()) {
      case 'G':
        grams = value;
        break;
      case 'MG':
        grams = value / 1000.0;
        break;
      case 'UG':
      case 'µG':
        grams = value / 1000000.0;
        break;
      default:
        return null; // skip IU and other units we can't safely convert
    }
    return grams * n.fromGrams;
  }

  static double? _servingGrams(Map<String, dynamic> food) {
    final double? size = _num(food['servingSize']);
    if (size == null) {
      return null;
    }
    final String unit =
        (food['servingSizeUnit'] as String?)?.toLowerCase() ?? '';
    if (unit.startsWith('g') || unit.startsWith('ml') || unit == 'grm') {
      return size;
    }
    return null;
  }

  static double? _num(dynamic v) {
    if (v is num) {
      return v.toDouble();
    }
    if (v is String) {
      return double.tryParse(v);
    }
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// UNIFIED LOOKUP — USDA primary, Open Food Facts fallback
// ═══════════════════════════════════════════════════════════════════════

class FoodLookup {
  static Future<List<FoodTemplate>> search(String query) async {
    List<FoodTemplate> r = <FoodTemplate>[];
    try {
      r = await Usda.search(query);
    } catch (_) {}
    if (r.isEmpty) {
      try {
        r = await OpenFoodFacts.search(query);
      } catch (_) {}
    }
    return dedupe(r, cap: 20);
  }

  /// Collapses near-identical names and caps the count so simple searches
  /// return a short, relevant list instead of a wall of variants.
  static List<FoodTemplate> dedupe(List<FoodTemplate> items, {int cap = 20}) {
    final Set<String> seen = <String>{};
    final List<FoodTemplate> out = <FoodTemplate>[];
    for (final FoodTemplate t in items) {
      final String key = t.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (seen.add(key)) {
        out.add(t);
      }
      if (out.length >= cap) {
        break;
      }
    }
    return out;
  }

  static Future<FoodTemplate?> barcode(String code) async {
    FoodTemplate? t;
    try {
      t = await Usda.fetchByBarcode(code);
    } catch (_) {}
    if (t != null) {
      return t;
    }
    try {
      return await OpenFoodFacts.fetchByBarcode(code);
    } catch (_) {
      return null;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
// MEAL MAKER — build a meal from raw ingredients, portion it by cal/grams
//
// We skip cooked-weight tracking (by design): a meal is just its ingredients
// and their nutrition. Portioning scales the whole meal by a single fraction,
// and per-ingredient amounts come out proportional to their raw grams.
// ═══════════════════════════════════════════════════════════════════════

/// Approximate cooked-weight / raw-weight ratio, matched by name keyword.
/// Used to ESTIMATE a dish's cooked weight without weighing the whole pot.
/// Default 1.0 (assume no change) for anything unrecognized; always editable.
double cookingYield(String name) {
  final String n = name.toLowerCase();
  bool has(List<String> kws) => kws.any((String k) => n.contains(k));
  if (has(<String>['brown rice'])) return 2.5;
  if (has(<String>['rice'])) return 2.7;
  if (has(<String>['pasta', 'spaghetti', 'macaroni', 'penne', 'noodle'])) {
    return 2.2;
  }
  if (has(<String>['oat'])) return 2.5;
  if (has(<String>['quinoa'])) return 2.7;
  if (has(<String>['lentil', 'dried bean', 'dry bean', 'chickpea', 'garbanzo'])) {
    return 2.4;
  }
  if (has(<String>['bacon'])) return 0.45;
  if (has(<String>['chicken breast'])) return 0.70;
  if (has(<String>['chicken', 'thigh'])) return 0.75;
  if (has(<String>['ground beef', 'ground turkey', 'ground pork', 'mince'])) {
    return 0.75;
  }
  if (has(<String>['beef', 'steak'])) return 0.70;
  if (has(<String>['pork'])) return 0.72;
  if (has(<String>['turkey'])) return 0.70;
  if (has(<String>['shrimp', 'prawn'])) return 0.85;
  if (has(<String>['salmon', 'tuna', 'fish', 'tilapia', 'cod'])) return 0.80;
  if (has(<String>['egg'])) return 0.90;
  if (has(<String>['spinach', 'kale', 'chard', 'collard'])) return 0.35;
  if (has(<String>['mushroom'])) return 0.50;
  if (has(<String>['onion'])) return 0.85;
  if (has(<String>['potato'])) return 0.90;
  if (has(<String>[
    'broccoli', 'cauliflower', 'carrot', 'pepper', 'zucchini', 'squash',
    'green bean', 'asparagus', 'vegetable'
  ])) {
    return 0.80;
  }
  return 1.0;
}

class MealIngredient {
  final FoodTemplate food; // per-100g nutrition + name
  final double rawGrams;
  final double yieldFactor; // cooked grams / raw grams
  MealIngredient(
      {required this.food, required this.rawGrams, double? yieldFactor})
      : yieldFactor = yieldFactor ?? cookingYield(food.name);

  // Cooking conserves calories/macros (only water weight changes), so all
  // nutrition is computed from the RAW amount.
  double get _s => rawGrams / 100.0;
  double get calories => food.kcal100 * _s;
  double get protein => food.protein100 * _s;
  double get fat => food.fat100 * _s;
  double get carbs => food.carbs100 * _s;
  Map<String, double> get nutrients => food.nutrients100
      .map((String k, double v) => MapEntry<String, double>(k, v * _s));

  // Estimated weight on the plate after cooking.
  double get cookedGrams => rawGrams * yieldFactor;

  MealIngredient copyWith({double? rawGrams, double? yieldFactor}) =>
      MealIngredient(
          food: food,
          rawGrams: rawGrams ?? this.rawGrams,
          yieldFactor: yieldFactor ?? this.yieldFactor);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'food': food.toJson(),
        'rawGrams': rawGrams,
        'yieldFactor': yieldFactor,
      };
  factory MealIngredient.fromJson(Map<String, dynamic> j) => MealIngredient(
      food: FoodTemplate.fromJson(j['food'] as Map<String, dynamic>),
      rawGrams: (j['rawGrams'] as num).toDouble(),
      yieldFactor: (j['yieldFactor'] as num?)?.toDouble());
}

class Meal {
  final String id;
  final String name;
  final List<MealIngredient> ingredients;
  final int createdAtMs; // for the 24h "leftovers" window

  Meal(
      {required this.id,
      required this.name,
      required this.ingredients,
      this.createdAtMs = 0});

  double get totalGrams =>
      ingredients.fold<double>(0, (double s, MealIngredient i) => s + i.rawGrams);
  // Estimated combined cooked weight — the number portions are measured against.
  double get cookedTotalGrams => ingredients.fold<double>(
      0, (double s, MealIngredient i) => s + i.cookedGrams);
  double get calories =>
      ingredients.fold<double>(0, (double s, MealIngredient i) => s + i.calories);
  double get protein =>
      ingredients.fold<double>(0, (double s, MealIngredient i) => s + i.protein);
  double get fat =>
      ingredients.fold<double>(0, (double s, MealIngredient i) => s + i.fat);
  double get carbs =>
      ingredients.fold<double>(0, (double s, MealIngredient i) => s + i.carbs);
  Map<String, double> get nutrients {
    final Map<String, double> m = <String, double>{};
    for (final MealIngredient i in ingredients) {
      i.nutrients.forEach((String k, double v) {
        m[k] = (m[k] ?? 0) + v;
      });
    }
    return m;
  }

  /// Still within the 24h leftovers window?
  bool isActive(int nowMs) =>
      createdAtMs > 0 && (nowMs - createdAtMs) < 24 * 60 * 60 * 1000;

  Meal copyWith(
          {String? name, List<MealIngredient>? ingredients, int? createdAtMs}) =>
      Meal(
          id: id,
          name: name ?? this.name,
          ingredients: ingredients ?? this.ingredients,
          createdAtMs: createdAtMs ?? this.createdAtMs);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'createdAtMs': createdAtMs,
        'ingredients':
            ingredients.map((MealIngredient i) => i.toJson()).toList(),
      };
  factory Meal.fromJson(Map<String, dynamic> j) => Meal(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAtMs: (j['createdAtMs'] as num?)?.toInt() ?? 0,
        ingredients: ((j['ingredients'] as List<dynamic>?) ?? <dynamic>[])
            .map((dynamic e) =>
                MealIngredient.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class IngredientPortion {
  final String name;
  final double grams;
  const IngredientPortion(this.name, this.grams);
}

class MealPortion {
  final double fraction;
  final double grams;
  final double calories;
  final double protein;
  final double fat;
  final double carbs;
  final Map<String, double> nutrients;
  final List<IngredientPortion> breakdown;
  const MealPortion({
    required this.fraction,
    required this.grams,
    required this.calories,
    required this.protein,
    required this.fat,
    required this.carbs,
    required this.nutrients,
    required this.breakdown,
  });
}

class MealMath {
  static MealPortion byCalories(Meal m, double cal) =>
      _scale(m, m.calories > 0 ? cal / m.calories : 0);

  /// [cookedGrams] is what you weigh on your plate.
  static MealPortion byCookedGrams(Meal m, double cookedGrams) =>
      _scale(m, m.cookedTotalGrams > 0 ? cookedGrams / m.cookedTotalGrams : 0);

  static MealPortion _scale(Meal m, double p) => MealPortion(
        fraction: p,
        grams: m.cookedTotalGrams * p, // cooked grams to weigh out
        calories: m.calories * p,
        protein: m.protein * p,
        fat: m.fat * p,
        carbs: m.carbs * p,
        nutrients: m.nutrients
            .map((String k, double v) => MapEntry<String, double>(k, v * p)),
        breakdown: m.ingredients
            .map((MealIngredient i) =>
                IngredientPortion(i.food.name, i.cookedGrams * p))
            .toList(),
      );

  /// Turns a portion into a loggable food entry for a given day.
  static FoodEntry toEntry(Meal meal, MealPortion portion,
      {required String id, required String date, String time = ''}) {
    return FoodEntry(
      id: id,
      date: date,
      time: time,
      name: meal.name,
      serving: '${_fmtG(portion.grams)} g cooked',
      calories: portion.calories,
      protein: portion.protein,
      fat: portion.fat,
      carbs: portion.carbs,
      nutrients: portion.nutrients,
      source: 'meal',
    );
  }

  static String _fmtG(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(0);
}
