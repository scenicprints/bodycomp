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
// PORTIONS ARE THIS APP'S JOB. Pantry sends one meal, every ingredient, each
// tagged with the pan it was cooked in. It never asks about plates: it does
// not know what was served, and this app already does that properly.
//
// What the pan tag is FOR. Anything stirred together can never be separated
// again, so it is portioned as one mass. Anything cooked APART can still be
// weighed on its own, and must be, because its density is nothing like the
// rest of the plate. Steak and broccoli are not interchangeable grams: a
// plate that is mostly steak carries far more protein and saturated fat than
// one meal-wide fraction would ever say, and those are the exact numbers
// being tracked.
//
// The cook weighs his plate, not the pan, so each component's share is his
// plate weight over what that component is RECKONED to have produced, from
// cookingYield(). That estimate is a known and accepted inaccuracy.
// ═══════════════════════════════════════════════════════════════════════

const String _kOwner = 'scenicprints';
const String _kRepo = 'pantry-data';
const String _kPath = 'cooked.json';

class CookedLine {
  final String name;
  final String? barcode;
  final double rawG;

  /// The pan it was cooked in. Empty means it was never cooked with anything
  /// — a garnish, or something added at the table.
  final String group;

  /// The pantry item the cook PAIRED this with, by its own name. The recipe
  /// says "chicken thighs, bone in"; the shelf says "Boneless, Skinless
  /// Chicken Breast Fillet (Just BARE)". Only the cook knows those are the
  /// same purchase, and pairing is how he says so — so match on this first
  /// and treat the recipe's wording as a last resort.
  final String pantryName;

  /// The pantry item's id, which is what pairing actually recorded.
  final String pantryId;

  const CookedLine(
      {required this.name,
      this.barcode,
      required this.rawG,
      this.group = '',
      this.pantryName = '',
      this.pantryId = ''});

  factory CookedLine.fromJson(Map<String, dynamic> j) => CookedLine(
        name: (j['name'] as String?) ?? '',
        pantryName: (j['pantry_name'] as String?) ?? '',
        pantryId: (j['pantry_id'] as String?) ?? '',
        barcode: j['barcode'] as String?,
        group: (j['group'] as String?) ?? '',
        rawG: (j['raw_g'] as num?)?.toDouble() ?? 0,
      );
}

class CookedMeal {
  final String id;
  final String recipe;
  final int servings;
  final int cookedAtMs;
  final bool pantrySettled;
  final List<CookedLine> lines;

  /// The separately-cooked components, in the order they appear. Anything
  /// with no pan sits under '' and is portioned as one mass.
  List<String> get components {
    final List<String> out = <String>[];
    for (final CookedLine l in lines) {
      if (!out.contains(l.group)) {
        out.add(l.group);
      }
    }
    return out;
  }

  List<CookedLine> linesIn(String group) =>
      lines.where((CookedLine l) => l.group == group).toList();

  const CookedMeal({
    required this.id,
    required this.recipe,
    required this.servings,
    required this.cookedAtMs,
    required this.pantrySettled,
    required this.lines,
  });

  factory CookedMeal.fromJson(Map<String, dynamic> j) => CookedMeal(
        id: (j['id'] as String?) ?? '',
        recipe: (j['recipe'] as String?) ?? '',
        servings: (j['servings'] as num?)?.round() ?? 0,
        cookedAtMs: (j['cooked_at_ms'] as num?)?.round() ?? 0,
        // Absent means an older Pantry build that hadn't subtracted; treat it
        // as unsettled so nothing is silently skipped.
        pantrySettled: (j['pantry_settled'] as bool?) ?? false,
        lines: ((j['lines'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(CookedLine.fromJson)
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
            .where((CookedMeal m) => m.lines.isNotEmpty)
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
        'lines': <Map<String, dynamic>>[
          for (final CookedLine l in m.lines)
            <String, dynamic>{
              'name': l.name,
              if (l.barcode != null) 'barcode': l.barcode,
              if (l.group.isNotEmpty) 'group': l.group,
              'raw_g': l.rawG,
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
  // What the cook PAIRED it with. This is the whole point of pairing, and
  // ignoring it in favour of matching the recipe's wording is why a meal came
  // over with everything paired and nothing recognised.
  if (line.pantryId.isNotEmpty) {
    for (final PantryFood f in foods) {
      if (f.pantryId == line.pantryId) {
        return f.template;
      }
    }
  }
  final String? bc = line.barcode;
  if (bc != null && bc.isNotEmpty) {
    for (final PantryFood f in foods) {
      if (f.template.barcode == bc) {
        return f.template;
      }
    }
  }
  // What the cook actually paired it with, exactly as the pantry spells it.
  if (line.pantryName.isNotEmpty) {
    for (final PantryFood f in foods) {
      if (f.name.trim().toLowerCase() ==
          line.pantryName.trim().toLowerCase()) {
        return f.template;
      }
    }
    final String paired = _key(line.pantryName);
    for (final PantryFood f in foods) {
      if (_key(f.name) == paired) {
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

/// A handoff resolved against the pantry, ready to portion.
class Handoff {
  /// Everything that went in the pans, at full weight. Goes in the meal list
  /// so leftovers and "cook again" work on what was actually cooked.
  final Meal batch;

  /// Ingredients per separately-cooked component, in order. The key is the
  /// pan name; '' is the catch-all for anything cooked with nothing.
  final Map<String, List<MealIngredient>> byComponent;

  /// Lines that matched nothing in the pantry, by name, so the cook is told
  /// rather than quietly shorted.
  final List<String> unmatched;

  const Handoff(
      {required this.batch,
      required this.byComponent,
      required this.unmatched});

  /// What a component is reckoned to have produced, from the yield table.
  double estimatedCooked(String component) =>
      (byComponent[component] ?? <MealIngredient>[])
          .fold<double>(0, (double s, MealIngredient i) => s + i.cookedGrams);

  /// The meal actually eaten, given what was weighed onto the plate from each
  /// component. Each component is scaled on its own: a plate that is mostly
  /// steak and a little broccoli cannot be described by one fraction, and
  /// those two are nothing alike per gram.
  Meal plate(Map<String, double> plateGrams, {String? name}) {
    final List<MealIngredient> out = <MealIngredient>[];
    byComponent.forEach((String component, List<MealIngredient> ings) {
      final double cooked = estimatedCooked(component);
      final double onPlate = plateGrams[component] ?? 0;
      if (cooked <= 0 || onPlate <= 0) {
        return;
      }
      // A yield estimate can sit under what really came out, so allow a share
      // above 1 rather than silently capping what he ate.
      final double share = (onPlate / cooked).clamp(0.0, 2.0);
      for (final MealIngredient i in ings) {
        out.add(MealIngredient(
            food: i.food,
            rawGrams: i.rawGrams * share,
            yieldFactor: i.yieldFactor));
      }
    });
    return Meal(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name ?? batch.name,
        ingredients: out);
  }
}

/// Resolve [h] against the pantry.
Handoff? buildHandoff(CookedMeal h, List<PantryFood> foods,
    {String Function()? newId}) {
  final List<MealIngredient> all = <MealIngredient>[];
  final Map<String, List<MealIngredient>> byComponent =
      <String, List<MealIngredient>>{};
  final List<String> unmatched = <String>[];

  for (final CookedLine l in h.lines) {
    if (l.rawG <= 0) {
      continue;
    }
    final FoodTemplate? t = _resolve(l, foods);
    if (t == null) {
      unmatched.add(l.pantryName.isNotEmpty ? l.pantryName : l.name);
      continue;
    }
    final MealIngredient mi = MealIngredient(food: t, rawGrams: l.rawG);
    all.add(mi);
    byComponent.putIfAbsent(l.group, () => <MealIngredient>[]).add(mi);
  }

  if (all.isEmpty) {
    return null;
  }
  final String Function() id =
      newId ?? () => DateTime.now().microsecondsSinceEpoch.toString();
  return Handoff(
    batch: Meal(
      id: id(),
      name: h.recipe,
      ingredients: all,
      createdAtMs: h.cookedAtMs,
    ),
    byComponent: byComponent,
    unmatched: unmatched,
  );
}
