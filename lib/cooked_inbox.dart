import 'dart:convert';

import 'package:http/http.dart' as http;

import 'food.dart';
import 'pantry_bridge.dart';

// ═══════════════════════════════════════════════════════════════════════
// COOKED INBOX — meals measured in the Pantry app, waiting to be logged.
//
// The Pantry app is where the cook is standing when the real numbers exist:
// the recipe says 480 g, the scale says 473 g. Rather than retyping the meal
// here, Pantry writes it to `cooked.json` in the shared pantry-data repo and
// this drains the queue.
//
// Division of labour, so nothing is counted twice:
//   Pantry   has ALREADY subtracted the raw grams and booked the spend.
//   BodyComp logs the food and must NOT subtract again. A handoff meal is
//   opened through _MealEditScreen with `existing` set, which is the path
//   that skips the subtraction, and `pantrySettled` says why.
//
// PORTIONS. The cook weighs what goes on his own plate, never what the pan
// produced, and does not want to be asked for the batch weight. So each pan's
// yield is ESTIMATED from cookingYield() and his share is plate ÷ estimate.
// That estimate is the denominator of everything logged off the dish, which
// is a known and accepted inaccuracy, not an oversight.
//
// It is per pan and not per meal on purpose: a plate is usually most of the
// chicken and a little of the rice, and one meal-wide fraction cannot say so.
// ═══════════════════════════════════════════════════════════════════════

const String _kOwner = 'scenicprints';
const String _kRepo = 'pantry-data';
const String _kPath = 'cooked.json';

class CookedLine {
  final String name;
  final String? barcode;
  final double rawG;
  const CookedLine({required this.name, this.barcode, required this.rawG});

  factory CookedLine.fromJson(Map<String, dynamic> j) => CookedLine(
        name: (j['name'] as String?) ?? '',
        barcode: j['barcode'] as String?,
        rawG: (j['raw_g'] as num?)?.toDouble() ?? 0,
      );
}

/// One pan. [plateG] is what the cook took from it, 0 when he had none.
class CookedGroup {
  final String name;
  final double plateG;
  final List<CookedLine> lines;
  const CookedGroup(
      {required this.name, required this.plateG, required this.lines});

  factory CookedGroup.fromJson(Map<String, dynamic> j) => CookedGroup(
        name: (j['name'] as String?) ?? '',
        plateG: (j['plate_g'] as num?)?.toDouble() ?? 0,
        lines: ((j['lines'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(CookedLine.fromJson)
            .toList(),
      );
}

class CookedMeal {
  final String id;
  final String recipe;
  final int servings;
  final int cookedAtMs;
  final bool pantrySettled;
  final List<CookedGroup> groups;

  const CookedMeal({
    required this.id,
    required this.recipe,
    required this.servings,
    required this.cookedAtMs,
    required this.pantrySettled,
    required this.groups,
  });

  factory CookedMeal.fromJson(Map<String, dynamic> j) => CookedMeal(
        id: (j['id'] as String?) ?? '',
        recipe: (j['recipe'] as String?) ?? '',
        servings: (j['servings'] as num?)?.round() ?? 0,
        cookedAtMs: (j['cooked_at_ms'] as num?)?.round() ?? 0,
        // Absent means an older Pantry build that hadn't subtracted; treat it
        // as unsettled so nothing is silently skipped.
        pantrySettled: (j['pantry_settled'] as bool?) ?? false,
        groups: ((j['groups'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(CookedGroup.fromJson)
            .toList(),
      );
}

class CookedInbox {
  static String get _token =>
      const String.fromEnvironment('PANTRY_DATA_TOKEN');
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$_kOwner/$_kRepo/contents/$_kPath');

  static Map<String, String> _headers() => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'BodyComp (github.com/scenicprints/bodycomp)',
        if (canWrite) 'Authorization': 'Bearer $_token',
      };

  static Future<(List<CookedMeal>, String?)?> _fetch() async {
    try {
      final http.Response r = await http
          .get(_uri, headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return (<CookedMeal>[], null);
      }
      if (r.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> j =
          jsonDecode(r.body) as Map<String, dynamic>;
      final String content =
          (j['content'] as String? ?? '').replaceAll('\n', '');
      final String? sha = j['sha'] as String?;
      if (content.isEmpty) {
        return (<CookedMeal>[], sha);
      }
      final dynamic d = jsonDecode(utf8.decode(base64.decode(content)));
      final List<dynamic> meals =
          (d is Map ? d['meals'] as List<dynamic>? : d as List<dynamic>?) ??
              <dynamic>[];
      return (
        meals
            .whereType<Map<String, dynamic>>()
            .map(CookedMeal.fromJson)
            .where((CookedMeal m) => m.groups.isNotEmpty)
            .toList(),
        sha
      );
    } catch (_) {
      return null;
    }
  }

  /// Meals waiting to be logged, oldest first. Null if the file couldn't be
  /// read at all, which the caller should treat as "don't know", not "none".
  static Future<List<CookedMeal>?> pending() async {
    final (List<CookedMeal>, String?)? r = await _fetch();
    if (r == null) {
      return null;
    }
    final List<CookedMeal> meals = r.$1
      ..sort((CookedMeal a, CookedMeal b) =>
          a.cookedAtMs.compareTo(b.cookedAtMs));
    return meals;
  }

  /// Take [id] out of the queue once it has been dealt with. Re-reads first,
  /// so a meal Pantry added in the meantime survives.
  static Future<bool> clear(String id) async {
    if (!canWrite) {
      return false;
    }
    final (List<CookedMeal>, String?)? current = await _fetch();
    if (current == null) {
      return false;
    }
    final List<Map<String, dynamic>> keep = <Map<String, dynamic>>[];
    for (final CookedMeal m in current.$1) {
      if (m.id == id) {
        continue;
      }
      keep.add(<String, dynamic>{
        'id': m.id,
        'recipe': m.recipe,
        'servings': m.servings,
        'cooked_at_ms': m.cookedAtMs,
        'pantry_settled': m.pantrySettled,
        'groups': <Map<String, dynamic>>[
          for (final CookedGroup g in m.groups)
            <String, dynamic>{
              'name': g.name,
              'plate_g': g.plateG,
              'lines': <Map<String, dynamic>>[
                for (final CookedLine l in g.lines)
                  <String, dynamic>{
                    'name': l.name,
                    if (l.barcode != null) 'barcode': l.barcode,
                    'raw_g': l.rawG,
                  }
              ],
            }
        ],
      });
    }
    final String body = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{'meals': keep});
    try {
      final http.Response r = await http
          .put(_uri,
              headers: <String, String>{
                ..._headers(),
                'content-type': 'application/json',
              },
              body: jsonEncode(<String, dynamic>{
                'message': 'Logged a cooked meal',
                'content': base64.encode(utf8.encode(body)),
                if (current.$2 != null) 'sha': current.$2,
              }))
          .timeout(const Duration(seconds: 20));
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }
}

// ── turning a handoff into meals ─────────────────────────────────────────

String _key(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)'), ' ')
    .replaceAll(RegExp(r'[^a-z]+'), ' ')
    .trim();

/// The pantry food a handoff line refers to. Barcode wins; then a normalised
/// name match either way round, shortest first so "chicken" can't beat
/// "chicken thighs".
FoodTemplate? _resolve(CookedLine line, List<PantryFood> foods) {
  final String? bc = line.barcode;
  if (bc != null && bc.isNotEmpty) {
    for (final PantryFood f in foods) {
      if (f.template.barcode == bc) {
        return f.template;
      }
    }
  }
  final String want = _key(line.name);
  if (want.isEmpty) {
    return null;
  }
  for (final PantryFood f in foods) {
    if (_key(f.name) == want) {
      return f.template;
    }
  }
  FoodTemplate? best;
  for (final PantryFood f in foods) {
    final String have = _key(f.name);
    if (have.isNotEmpty && (want.contains(have) || have.contains(want))) {
      if (best == null || have.length < _key(best.name).length) {
        best = f.template;
      }
    }
  }
  return best;
}

/// What a handoff turns into: the batch that was cooked, and the plate that
/// was eaten from it.
class HandoffMeals {
  /// Everything that went in the pans, at full weight. Goes in the meal list
  /// so leftovers and "cook again" still work.
  final Meal batch;

  /// The share that ended up on the plate, ready to log.
  final Meal plate;

  /// Lines that matched nothing in the pantry, by name, so the cook can be
  /// told rather than quietly shorted.
  final List<String> unmatched;

  const HandoffMeals(
      {required this.batch, required this.plate, required this.unmatched});

  bool get isEmpty => batch.ingredients.isEmpty;
}

/// Build both meals from [h].
///
/// Each pan's share is its plate weight over its ESTIMATED cooked weight, so
/// a plate that took most of the chicken and a spoon of rice logs as exactly
/// that. A pan the cook took nothing from contributes nothing to the plate but
/// still counts as cooked.
HandoffMeals? buildHandoffMeals(CookedMeal h, List<PantryFood> foods,
    {String Function()? newId}) {
  final List<MealIngredient> batch = <MealIngredient>[];
  final List<MealIngredient> plate = <MealIngredient>[];
  final List<String> unmatched = <String>[];

  for (final CookedGroup g in h.groups) {
    final List<MealIngredient> mine = <MealIngredient>[];
    for (final CookedLine l in g.lines) {
      if (l.rawG <= 0) {
        continue;
      }
      final FoodTemplate? t = _resolve(l, foods);
      if (t == null) {
        unmatched.add(l.name);
        continue;
      }
      mine.add(MealIngredient(food: t, rawGrams: l.rawG));
    }
    if (mine.isEmpty) {
      continue;
    }
    batch.addAll(mine);

    final double cooked = mine.fold<double>(
        0, (double s, MealIngredient i) => s + i.cookedGrams);
    // A yield estimate can sit under what actually came out, so allow a share
    // above 1 rather than silently capping what he ate.
    final double share =
        (cooked <= 0 || g.plateG <= 0) ? 0 : (g.plateG / cooked).clamp(0.0, 2.0);
    if (share <= 0) {
      continue;
    }
    for (final MealIngredient i in mine) {
      plate.add(MealIngredient(
          food: i.food,
          rawGrams: i.rawGrams * share,
          yieldFactor: i.yieldFactor));
    }
  }

  if (batch.isEmpty) {
    return null;
  }
  final String Function() id =
      newId ?? () => DateTime.now().microsecondsSinceEpoch.toString();
  return HandoffMeals(
    batch: Meal(
      id: id(),
      name: h.recipe,
      ingredients: batch,
      createdAtMs: h.cookedAtMs,
    ),
    plate: Meal(id: id(), name: h.recipe, ingredients: plate),
    unmatched: unmatched,
  );
}
