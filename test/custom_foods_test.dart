import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/custom_foods.dart';

// A realistic OCR dump from a US Nutrition Facts panel. ML Kit usually keeps
// rough line order but drops some "Total" prefixes and merges spacing.
const String _cereal = '''
Nutrition Facts
8 servings per container
Serving size  2/3 cup (55g)
Amount per serving
Calories  230
% Daily Value*
Total Fat 8g        10%
  Saturated Fat 1g  5%
  Trans Fat 0g
Cholesterol 0mg     0%
Sodium 160mg        7%
Total Carbohydrate 37g  13%
  Dietary Fiber 4g  14%
  Total Sugars 12g
Protein 3g
''';

// A noisier capture: prefixes dropped, "Calories from Fat" present as a trap.
const String _noisy = '''
NUTRITION FACTS Serving Size 1 bar (40 g)
Calories 190 Calories from Fat 70
Fat 7g Sodium 95mg
Carbohydrate 27g Fiber 2g Sugars 14g
Protein 4g
''';

void main() {
  group('Nutrition label parsing', () {
    test('reads serving, calories, and macros off a clean label', () {
      final LabelParse p = parseNutritionLabel(_cereal);
      expect(p.calories, 230);
      expect(p.fat, 8);
      expect(p.carbs, 37);
      expect(p.protein, 3);
      expect(p.fiber, 4);
      expect(p.sugars, 12);
      expect(p.sodium, 160);
      expect(p.servingGrams, 55);
      expect(p.servingRaw, contains('2/3 cup'));
      expect(p.hasAnything, isTrue);
    });

    test('ignores "Calories from Fat" and survives dropped prefixes', () {
      final LabelParse p = parseNutritionLabel(_noisy);
      expect(p.calories, 190); // NOT 70 from "Calories from Fat"
      expect(p.fat, 7);
      expect(p.carbs, 27);
      expect(p.protein, 4);
      expect(p.fiber, 2);
      expect(p.sugars, 14);
      expect(p.sodium, 95);
      expect(p.servingGrams, 40);
    });

    test('returns nulls (not zeros) when nothing is found', () {
      final LabelParse p = parseNutritionLabel('just some random text');
      expect(p.calories, isNull);
      expect(p.protein, isNull);
      expect(p.hasAnything, isFalse);
    });
  });

  group('CustomFood scaling', () {
    final CustomFood bar = CustomFood(
      id: 'a',
      name: 'Protein Bar',
      serving: '1 bar',
      servingGrams: 40,
      calories: 190,
      protein: 4,
      fat: 7,
      carbs: 27,
      nutrients: <String, double>{'fiber': 2, 'sodium': 95},
      source: 'label',
      updatedAtMs: 1000,
    );

    test('×1 serving keeps the serving label and macros', () {
      final e = bar.toEntry(id: 'e1', date: '2026-06-30', quantity: 1);
      expect(e.serving, '1 bar');
      expect(e.calories, 190);
      expect(e.nutrients['fiber'], 2);
    });

    test('×2.5 servings scales every number', () {
      final e = bar.toEntry(id: 'e2', date: '2026-06-30', quantity: 2.5);
      expect(e.calories, 475);
      expect(e.protein, 10);
      expect(e.nutrients['sodium'], 95 * 2.5);
      expect(e.serving, '2.5 × 1 bar');
    });

    test('round-trips through JSON', () {
      final CustomFood back = CustomFood.fromJson(bar.toJson());
      expect(back.name, 'Protein Bar');
      expect(back.calories, 190);
      expect(back.servingGrams, 40);
      expect(back.nutrients['sodium'], 95);
      expect(back.source, 'label');
      expect(back.updatedAtMs, 1000);
    });
  });

  group('Sync merge (last-write-wins by id)', () {
    CustomFood f(String id, String name, int ts, {bool deleted = false}) =>
        CustomFood(
          id: id,
          name: name,
          serving: '1 serving',
          calories: 100,
          protein: 0,
          fat: 0,
          carbs: 0,
          updatedAtMs: ts,
          deleted: deleted,
        );

    test('newer updatedAtMs wins for the same id', () {
      final List<CustomFood> local = <CustomFood>[f('1', 'Old Name', 100)];
      final List<CustomFood> remote = <CustomFood>[f('1', 'New Name', 200)];
      final List<CustomFood> m = CustomFoodStore.mergeFoods(local, remote);
      expect(m.length, 1);
      expect(m.first.name, 'New Name');
    });

    test('unions distinct ids and sorts by name', () {
      final List<CustomFood> local = <CustomFood>[f('1', 'Zucchini', 100)];
      final List<CustomFood> remote = <CustomFood>[f('2', 'Apple', 100)];
      final List<CustomFood> m = CustomFoodStore.mergeFoods(local, remote);
      expect(m.map((CustomFood x) => x.name), <String>['Apple', 'Zucchini']);
    });

    test('a newer tombstone deletes across devices and sorts last', () {
      final List<CustomFood> local = <CustomFood>[f('1', 'Bread', 100)];
      final List<CustomFood> remote = <CustomFood>[
        f('1', 'Bread', 200, deleted: true),
        f('2', 'Apple', 100),
      ];
      final List<CustomFood> m = CustomFoodStore.mergeFoods(local, remote);
      expect(m.firstWhere((CustomFood x) => x.id == '1').deleted, isTrue);
      expect(m.last.id, '1'); // tombstones sort last
    });

    test('encode → decode round-trips the file format', () {
      final List<CustomFood> foods = <CustomFood>[f('1', 'Apple', 100)];
      final String s = CustomFoodStore.encodeFile(foods);
      final List<CustomFood> back = CustomFoodStore.decodeFile(s);
      expect(back.length, 1);
      expect(back.first.name, 'Apple');
    });
  });
}
