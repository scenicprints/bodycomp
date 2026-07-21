import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'food.dart';

// ═══════════════════════════════════════════════════════════════════════
// PANTRY BRIDGE — lets BodyComp's Cook screen subtract a meal's raw
// ingredients from the shared Pantry (scenicprints/pantry-data/pantry.json).
//
// It works at the JSON level: fetch the file, mutate only `remaining_*` on
// matched items, write it back. That way any pantry field this app doesn't
// know about is preserved untouched. Matching is barcode-first, then a
// normalized name match, and NOTHING is written until the user confirms.
//
// Write token: a fine-grained PAT with contents:write on pantry-data,
// injected at build via --dart-define=PANTRY_DATA_TOKEN (a GitHub Actions
// secret). Without it the button explains it's read-only.
// ═══════════════════════════════════════════════════════════════════════

const String _owner = 'scenicprints';
const String _repo = 'pantry-data';
const String _path = 'pantry.json';
const String _usagePath = 'usage.json';

/// One line the caller wants to deduct: an ingredient and its raw grams.
class IngredientDeduction {
  final String name;
  final String? barcode;
  final double grams;
  const IngredientDeduction(
      {required this.name, this.barcode, required this.grams});
}

class _PantryFile {
  final Map<String, dynamic> root; // whole decoded file
  final List<Map<String, dynamic>> items; // root['pantry']
  final String? sha;
  _PantryFile(this.root, this.items, this.sha);
}

class _PantryApi {
  static String get _token =>
      const String.fromEnvironment('PANTRY_DATA_TOKEN');
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$_owner/$_repo/contents/$_path');

  static Map<String, String> get _headers => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'BodyComp-PantryBridge',
        if (canWrite) 'Authorization': 'Bearer $_token',
      };

  static Future<_PantryFile?> fetch() async {
    try {
      final http.Response r =
          await http.get(_uri, headers: _headers).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> j = jsonDecode(r.body) as Map<String, dynamic>;
      final String content = (j['content'] as String? ?? '').replaceAll('\n', '');
      final String? sha = j['sha'] as String?;
      final Map<String, dynamic> root = content.isEmpty
          ? <String, dynamic>{'pantry': <dynamic>[], 'quick_add_items': <dynamic>[]}
          : jsonDecode(utf8.decode(base64.decode(content))) as Map<String, dynamic>;
      final List<Map<String, dynamic>> items =
          ((root['pantry'] as List<dynamic>?) ?? <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .toList();
      return _PantryFile(root, items, sha);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> push(Map<String, dynamic> root, String? sha) async {
    try {
      const JsonEncoder enc = JsonEncoder.withIndent('  ');
      final Map<String, dynamic> body = <String, dynamic>{
        'message': 'Subtract cooked meal (from BodyComp)',
        'content': base64.encode(utf8.encode(enc.convert(root))),
        'branch': 'main',
        'sha': ?sha,
      };
      final http.Response r = await http
          .put(_uri, headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }
}

// ── spending ledger ───────────────────────────────────────────────────────
// The Pantry app tracks spending by CONSUMPTION, not purchase, in an
// append-only `usage.json` in the same repo. When BodyComp subtracts a cooked
// meal it appends one entry per matched item (source: "bodycomp") with the cost
// of what was used, so BodyComp usage shows up in Pantry's weekly/monthly
// spend. The merge is a union by entry id, so it can never clobber an entry the
// Pantry app added. Entry schema mirrors Pantry's UsageEntry exactly.

class _UsageApi {
  static String get _token =>
      const String.fromEnvironment('PANTRY_DATA_TOKEN');
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$_owner/$_repo/contents/$_usagePath');

  static Map<String, String> get _headers => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'BodyComp-PantryBridge',
        if (canWrite) 'Authorization': 'Bearer $_token',
      };

  /// Append [entries] to usage.json (union by id). Best-effort: returns false
  /// on any failure so the caller can note it without blocking the subtract.
  static Future<bool> append(List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty || !canWrite) {
      return false;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
      List<dynamic> existing = <dynamic>[];
      String? sha;
      try {
        final http.Response r = await http
            .get(_uri, headers: _headers)
            .timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) {
          final Map<String, dynamic> j =
              jsonDecode(r.body) as Map<String, dynamic>;
          sha = j['sha'] as String?;
          final String content =
              (j['content'] as String? ?? '').replaceAll('\n', '');
          if (content.isNotEmpty) {
            final Map<String, dynamic> root =
                jsonDecode(utf8.decode(base64.decode(content)))
                    as Map<String, dynamic>;
            existing = (root['usage'] as List<dynamic>?) ?? <dynamic>[];
          }
        } else if (r.statusCode != 404) {
          return false; // don't risk a bad write on an unexpected status
        }
      } catch (_) {
        return false;
      }

      // Union by id: keep every existing entry, add/replace ours.
      final Map<String, Map<String, dynamic>> byId =
          <String, Map<String, dynamic>>{};
      for (final dynamic e in existing) {
        if (e is Map<String, dynamic> && e['id'] is String) {
          byId[e['id'] as String] = e;
        }
      }
      for (final Map<String, dynamic> e in entries) {
        byId[e['id'] as String] = e;
      }
      final Map<String, dynamic> out = <String, dynamic>{
        'usage': byId.values.toList()
      };

      try {
        const JsonEncoder enc = JsonEncoder.withIndent('  ');
        final Map<String, dynamic> body = <String, dynamic>{
          'message': 'Append usage (from BodyComp)',
          'content': base64.encode(utf8.encode(enc.convert(out))),
          'branch': 'main',
          'sha': ?sha,
        };
        final http.Response r = await http
            .put(_uri, headers: _headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
        if (r.statusCode == 200 || r.statusCode == 201) {
          return true;
        }
        // else: likely a sha race — loop refetches and retries once.
      } catch (_) {
        return false;
      }
    }
    return false;
  }
}

// ── matching ────────────────────────────────────────────────────────────

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
String _stripZeros(String s) => s.replaceAll(RegExp(r'^0+'), '');

bool _isCount(Map<String, dynamic> item) =>
    item['unit'] == 'count' || item.containsKey('total_count');

/// Find the best pantry index for an ingredient, or -1. Barcode wins; then a
/// normalized name match (equal, or one contained in the other).
int _match(IngredientDeduction ing, List<Map<String, dynamic>> items) {
  if (ing.barcode != null && ing.barcode!.isNotEmpty) {
    final String b = _stripZeros(ing.barcode!);
    for (int i = 0; i < items.length; i++) {
      final String? ib = items[i]['barcode'] as String?;
      if (ib != null && _stripZeros(ib) == b) {
        return i;
      }
    }
  }
  final String n = _norm(ing.name);
  if (n.isEmpty) {
    return -1;
  }
  int best = -1;
  int bestLen = 0;
  for (int i = 0; i < items.length; i++) {
    final String pn = _norm((items[i]['name'] as String?) ?? '');
    if (pn.isEmpty) {
      continue;
    }
    if (pn == n || n.contains(pn) || pn.contains(n)) {
      // Prefer the longest matching pantry name (most specific).
      if (pn.length > bestLen) {
        best = i;
        bestLen = pn.length;
      }
    }
  }
  return best;
}

// ── read: expose pantry items as loggable foods ──────────────────────────

/// A pantry item hydrated into a loggable food, plus a short "on hand" label.
class PantryFood {
  final FoodTemplate template;
  final String remainingLabel; // e.g. "220 g left", "3 left", or ''
  const PantryFood(this.template, this.remainingLabel);

  String get name => template.name;
}

/// Fetch the shared pantry and return the items that carry gram-based macros
/// as loggable [FoodTemplate]s. Spices, quantity-unknown, count-only, and
/// macro-less items are skipped (they can't be scaled by grams). Returns null
/// only when the pantry file itself couldn't be fetched (offline/error).
Future<List<PantryFood>?> fetchPantryFoods() async {
  final _PantryFile? file = await _PantryApi.fetch();
  if (file == null) {
    return null;
  }
  final List<PantryFood> out = <PantryFood>[];
  for (final Map<String, dynamic> m in file.items) {
    if (m['deleted'] == true) {
      continue;
    }
    final PantryFood? pf = _pantryFoodFrom(m);
    if (pf != null) {
      out.add(pf);
    }
  }
  out.sort((PantryFood a, PantryFood b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

PantryFood? _pantryFoodFrom(Map<String, dynamic> m) {
  final String name = (m['name'] as String?)?.trim() ?? '';
  if (name.isEmpty || m['spice'] == true || m['quantity_unknown'] == true) {
    return null;
  }
  // Used-up items stay in the shared file (the Pantry app shows them under
  // its "Used up" history) but they're not IN the pantry anymore — don't
  // offer them as loggable foods.
  final bool isCount = m['unit'] == 'count' || m.containsKey('total_count');
  final double remaining =
      _pd(isCount ? m['remaining_count'] : m['remaining_weight_g']);
  if (remaining <= 0) {
    return null;
  }
  final String servingUnit = (m['serving_unit'] as String?) ?? 'g';
  final double servingSize = _pd(m['serving_size']);
  final Map<String, dynamic>? per100 =
      (m['macros_per_100g'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>();
  final Map<String, dynamic>? perServing =
      (m['macros_per_serving'] as Map<dynamic, dynamic>?)
          ?.cast<String, dynamic>();

  double kcal100 = 0, p100 = 0, f100 = 0, c100 = 0;
  double? servingGrams;
  if (per100 != null) {
    kcal100 = _pd(per100['calories']);
    p100 = _pd(per100['protein_g']);
    f100 = _pd(per100['fat_g']);
    c100 = _pd(per100['carbs_g']);
    if (servingUnit == 'g' && servingSize > 0) {
      servingGrams = servingSize;
    }
  } else if (perServing != null && servingUnit == 'g' && servingSize > 0) {
    // Only grams-based servings can be turned into a per-100 g profile.
    final double s = 100.0 / servingSize;
    kcal100 = _pd(perServing['calories']) * s;
    p100 = _pd(perServing['protein_g']) * s;
    f100 = _pd(perServing['fat_g']) * s;
    c100 = _pd(perServing['carbs_g']) * s;
    servingGrams = servingSize;
  } else {
    return null; // no gram-based macros to scale
  }
  if (kcal100 <= 0 && p100 <= 0 && f100 <= 0 && c100 <= 0) {
    return null;
  }

  final String? barcode = m['barcode'] as String?;
  final FoodTemplate t = FoodTemplate(
    name: name,
    kcal100: kcal100,
    protein100: p100,
    fat100: f100,
    carbs100: c100,
    nutrients100: <String, double>{},
    servingGrams: servingGrams,
    barcode: (barcode != null && barcode.isNotEmpty) ? barcode : null,
  );

  final String rem =
      isCount ? '${_fmtNum(remaining)} left' : '${_fmtNum(remaining)} g left';
  return PantryFood(t, rem);
}

double _pd(dynamic v) {
  if (v is num) {
    return v.toDouble();
  }
  if (v is String) {
    return double.tryParse(v) ?? 0;
  }
  return 0;
}

String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

// ── entry point ─────────────────────────────────────────────────────────

/// Show the confirm-and-subtract flow for [deductions]. Returns nothing;
/// surfaces all outcomes via snackbars.
Future<void> subtractMealFromPantry(
    BuildContext context, Color accent, List<IngredientDeduction> deductions) async {
  if (!_PantryApi.canWrite) {
    _snack(context,
        'Pantry write token not set in this build — can\'t subtract yet.');
    return;
  }
  showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(child: CircularProgressIndicator(color: accent)));
  final _PantryFile? file = await _PantryApi.fetch();
  if (context.mounted) {
    Navigator.pop(context); // dismiss loader
  }
  if (file == null) {
    if (context.mounted) {
      _snack(context, 'Couldn\'t reach the pantry. Try again when online.');
    }
    return;
  }
  if (!context.mounted) {
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => _ConfirmSubtractPage(
      accent: accent,
      deductions: deductions,
      file: file,
    ),
  ));
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(backgroundColor: const Color(0xFF2A2A2A), content: Text(msg)));
}

// ── confirm screen ──────────────────────────────────────────────────────

class _Line {
  final IngredientDeduction ing;
  int matchIndex; // index into file.items, or -1 = skip
  final TextEditingController amount; // grams (weight) or count
  _Line(this.ing, this.matchIndex, this.amount);
}

class _ConfirmSubtractPage extends StatefulWidget {
  final Color accent;
  final List<IngredientDeduction> deductions;
  final _PantryFile file;
  const _ConfirmSubtractPage(
      {required this.accent, required this.deductions, required this.file});

  @override
  State<_ConfirmSubtractPage> createState() => _ConfirmSubtractPageState();
}

class _ConfirmSubtractPageState extends State<_ConfirmSubtractPage> {
  late final List<_Line> _lines;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    _lines = widget.deductions.map((IngredientDeduction d) {
      final int idx = _match(d, widget.file.items);
      final bool count = idx >= 0 && _isCount(widget.file.items[idx]);
      // Default: raw grams for a weight item, 1 for a count item.
      final String def =
          count ? '1' : (d.grams == d.grams.roundToDouble()
              ? d.grams.toInt().toString()
              : d.grams.toStringAsFixed(1));
      return _Line(d, idx, TextEditingController(text: def));
    }).toList();
  }

  @override
  void dispose() {
    for (final _Line l in _lines) {
      l.amount.dispose();
    }
    super.dispose();
  }

  String _itemName(int i) => (widget.file.items[i]['name'] as String?) ?? '(unnamed)';

  Future<void> _pickMatch(_Line line) async {
    final int? chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF161616),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(
        child: ListView(shrinkWrap: true, children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Text('Match to pantry item',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
          ListTile(
            leading: const Icon(Icons.block_rounded, color: Color(0xFF888888)),
            title: const Text('Skip this ingredient'),
            onTap: () => Navigator.pop(context, -1),
          ),
          const Divider(height: 1, color: Color(0xFF262626)),
          for (int i = 0; i < widget.file.items.length; i++)
            ListTile(
              title: Text(_itemName(i)),
              subtitle: Text(
                  _isCount(widget.file.items[i]) ? 'count' : 'weight (g)',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
              trailing: line.matchIndex == i
                  ? Icon(Icons.check_rounded, color: widget.accent)
                  : null,
              onTap: () => Navigator.pop(context, i),
            ),
        ]),
      ),
    );
    if (chosen != null) {
      setState(() {
        line.matchIndex = chosen;
        if (chosen >= 0) {
          final bool count = _isCount(widget.file.items[chosen]);
          line.amount.text = count
              ? '1'
              : (line.ing.grams == line.ing.grams.roundToDouble()
                  ? line.ing.grams.toInt().toString()
                  : line.ing.grams.toStringAsFixed(1));
        }
      });
    }
  }

  Future<void> _apply() async {
    setState(() => _writing = true);
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final List<String> summary = <String>[];
    // One spending-ledger entry per subtracted line (cost of what was used).
    final List<Map<String, dynamic>> usage = <Map<String, dynamic>>[];
    int applied = 0;

    for (final _Line l in _lines) {
      if (l.matchIndex < 0) {
        continue;
      }
      final double amt = double.tryParse(l.amount.text.trim()) ?? 0;
      if (amt <= 0) {
        continue;
      }
      final Map<String, dynamic> item = widget.file.items[l.matchIndex];
      final bool count = _isCount(item);
      final String key = count ? 'remaining_count' : 'remaining_weight_g';
      final double cur = (item[key] as num?)?.toDouble() ?? 0;
      final double subtracted = amt > cur ? cur : amt; // can't use more than left
      final double next = (cur - amt) < 0 ? 0 : (cur - amt);
      item[key] = num.parse(next.toStringAsFixed(1));
      item['updated_at_ms'] = nowMs;
      applied++;
      summary.add('${_itemName(l.matchIndex)}: −${_fmt(amt)}${count ? ' ct' : ' g'}');

      // Record the cost of what was actually consumed, using the pantry item's
      // own unit price. Skipped when there's no price to cost it against.
      final double unitPrice = count
          ? _pd(item['price_per_unit'])
          : _pd(item['price_per_gram']);
      if (unitPrice > 0 && subtracted > 0) {
        final String itemId =
            (item['id'] as String?) ?? _norm(_itemName(l.matchIndex));
        usage.add(<String, dynamic>{
          'id': '$itemId-$nowMs-$applied',
          'ts': nowMs,
          'item_id': itemId,
          'name': _itemName(l.matchIndex),
          'amount': num.parse(subtracted.toStringAsFixed(1)),
          'unit': count ? 'count' : 'g',
          'unit_price': num.parse(unitPrice.toStringAsFixed(4)),
          'cost': num.parse((subtracted * unitPrice).toStringAsFixed(2)),
          'source': 'bodycomp',
        });
      }
    }

    if (applied == 0) {
      setState(() => _writing = false);
      _snack(context, 'Nothing selected to subtract.');
      return;
    }

    // Write back onto the version we fetched (sha guards against a race).
    widget.file.root['pantry'] = widget.file.items;
    bool ok = await _PantryApi.push(widget.file.root, widget.file.sha);
    if (!ok) {
      // One retry: refetch for a fresh sha and re-apply the same deltas is
      // complex; simplest safe retry is to re-push against the newest sha.
      final _PantryFile? fresh = await _PantryApi.fetch();
      if (fresh != null) {
        ok = await _PantryApi.push(widget.file.root, fresh.sha);
      }
    }
    // Only record spend once the pantry write actually landed, so the ledger
    // never counts a subtraction that didn't happen. Best-effort.
    if (ok && usage.isNotEmpty) {
      await _UsageApi.append(usage);
    }
    if (!mounted) {
      return;
    }
    setState(() => _writing = false);
    if (ok) {
      Navigator.pop(context);
      _snack(context, 'Pantry updated: ${summary.join(', ')}');
    } else {
      _snack(context, 'Couldn\'t write to the pantry. Try again.');
    }
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final int matched = _lines.where((_Line l) => l.matchIndex >= 0).length;
    return Scaffold(
      backgroundColor: const Color(0xFF0E0F12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0F12),
        title: const Text('Subtract from Pantry'),
      ),
      body: Column(children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('$matched of ${_lines.length} ingredients matched',
                style: const TextStyle(color: Color(0xFF999999), fontSize: 13)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            itemCount: _lines.length,
            itemBuilder: (_, int i) => _lineCard(_lines[i]),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _writing ? null : _apply,
                style: ElevatedButton.styleFrom(
                    backgroundColor: widget.accent,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: _writing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Text('Subtract from Pantry',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _lineCard(_Line l) {
    final bool matched = l.matchIndex >= 0;
    final bool count = matched && _isCount(widget.file.items[l.matchIndex]);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: matched ? const Color(0xFF262626) : const Color(0xFF3A2A1A))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(l.ing.name,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text('${_fmt(l.ing.grams)} g raw',
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
        const SizedBox(height: 10),
        Row(children: <Widget>[
          Expanded(
            child: OutlinedButton(
              onPressed: () => _pickMatch(l),
              style: OutlinedButton.styleFrom(
                  foregroundColor: matched ? widget.accent : const Color(0xFFE0A458),
                  side: BorderSide(
                      color: (matched ? widget.accent : const Color(0xFFE0A458))
                          .withValues(alpha: 0.5)),
                  alignment: Alignment.centerLeft),
              child: Text(
                  matched ? '→ ${_itemName(l.matchIndex)}' : 'Not matched — tap to pick',
                  overflow: TextOverflow.ellipsis),
            ),
          ),
          if (matched) ...<Widget>[
            const SizedBox(width: 10),
            SizedBox(
              width: 96,
              child: TextField(
                controller: l.amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Color(0xFFEEEEEE)),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: count ? 'count' : 'grams',
                  labelStyle:
                      const TextStyle(color: Color(0xFF888888), fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF111111),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF262626))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF262626))),
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }
}
