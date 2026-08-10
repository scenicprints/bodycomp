import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/food.dart';

FoodTemplate _food(String name,
        {double kcal = 165, double p = 31, double f = 3.6, double c = 0}) =>
    FoodTemplate(
        name: name,
        kcal100: kcal,
        protein100: p,
        fat100: f,
        carbs100: c,
        nutrients100: const <String, double>{'sodium': 74});

/// A batch cooked for the week: 1 kg chicken + 500 g rice.
Meal _batch({int createdAtMs = 0, bool saved = false}) => Meal(
      id: 'm1',
      name: 'Weekly chicken and rice',
      createdAtMs: createdAtMs,
      saved: saved,
      ingredients: <MealIngredient>[
        MealIngredient(
            food: _food('Chicken breast'), rawGrams: 1000, yieldFactor: 0.75),
        MealIngredient(
            food: _food('Rice', kcal: 360, p: 7, f: 1, c: 79),
            rawGrams: 500,
            yieldFactor: 2.5),
      ],
    );

void main() {
  const int day = 24 * 60 * 60 * 1000;

  group('saved flag', () {
    test('round-trips through JSON', () {
      final Meal m = _batch(createdAtMs: 1700000000000, saved: true);
      final Meal back = Meal.fromJson(m.toJson());
      expect(back.saved, true);
      expect(back.name, 'Weekly chicken and rice');
      expect(back.ingredients.length, 2);
      expect(back.createdAtMs, 1700000000000);
    });

    test('defaults to false, and older saves without the key stay false', () {
      expect(_batch().saved, false);
      final Map<String, dynamic> legacy = _batch().toJson()
        ..remove('saved');
      expect(Meal.fromJson(legacy).saved, false);
      // An unsaved meal shouldn't even write the key.
      expect(_batch().toJson().containsKey('saved'), false);
    });

    test('copyWith toggles saved without disturbing anything else', () {
      final Meal m = _batch(createdAtMs: 5, saved: false);
      final Meal s = m.copyWith(saved: true);
      expect(s.saved, true);
      expect(s.id, m.id);
      expect(s.name, m.name);
      expect(s.createdAtMs, 5);
      expect(s.ingredients.length, m.ingredients.length);
      expect(s.copyWith(saved: false).saved, false);
    });
  });

  group('the 24h window vs a saved batch', () {
    test('a fresh meal is active; a two-day-old one is not', () {
      final int now = 10 * day;
      expect(_batch(createdAtMs: now).isActive(now), true);
      expect(_batch(createdAtMs: now - 2 * day).isActive(now), false);
    });

    test('the prune rule keeps saved meals and drops expired leftovers', () {
      final int now = 10 * day;
      final List<Meal> meals = <Meal>[
        _batch(createdAtMs: now, saved: false), // fresh leftover
        Meal(
            id: 'old',
            name: 'Old leftover',
            createdAtMs: now - 3 * day,
            ingredients: _batch().ingredients), // expired, not saved
        Meal(
            id: 'lib',
            name: 'Saved batch',
            createdAtMs: now - 9 * day,
            saved: true,
            ingredients: _batch().ingredients), // ancient but saved
      ];
      // This mirrors the rule the Cook screen applies when a new meal is added.
      final List<Meal> kept =
          meals.where((Meal m) => m.isActive(now) || m.saved).toList();
      expect(kept.map((Meal m) => m.id).toList(), <String>['m1', 'lib']);
    });
  });

  group('logging a different amount every day', () {
    test('portions by cooked grams scale every macro proportionally', () {
      final Meal m = _batch(saved: true);
      // 1000 g raw chicken -> 750 g cooked; 500 g raw rice -> 1250 g cooked.
      expect(m.cookedTotalGrams, closeTo(2000, 0.01));

      final MealPortion small = MealMath.byCookedGrams(m, 200);
      final MealPortion big = MealMath.byCookedGrams(m, 400);
      expect(small.fraction, closeTo(0.1, 1e-9));
      expect(big.calories, closeTo(small.calories * 2, 0.01));
      expect(big.protein, closeTo(small.protein * 2, 0.01));
      expect(small.calories, closeTo(m.calories * 0.1, 0.01));
    });

    test('a week of different portions never exceeds the batch total', () {
      final Meal m = _batch(saved: true);
      const List<double> week = <double>[250, 310, 180, 400, 220, 300, 340];
      double cal = 0, grams = 0;
      for (final double g in week) {
        final MealPortion p = MealMath.byCookedGrams(m, g);
        cal += p.calories;
        grams += g;
      }
      expect(grams, 2000); // exactly the batch
      expect(cal, closeTo(m.calories, 0.5));
    });

    test('each portion becomes a dated food entry naming the meal', () {
      final Meal m = _batch(saved: true);
      final MealPortion p = MealMath.byCookedGrams(m, 300);
      final FoodEntry e = MealMath.toEntry(m, p,
          id: 'e1', date: '2026-08-12', time: '08:15');
      expect(e.date, '2026-08-12');
      expect(e.name, 'Weekly chicken and rice');
      expect(e.serving, contains('300 g cooked'));
      expect(e.calories, closeTo(p.calories, 0.01));
      expect(e.source, 'meal');
      // Two different days can log two different amounts from the same meal.
      final FoodEntry e2 = MealMath.toEntry(
          m, MealMath.byCookedGrams(m, 150),
          id: 'e2', date: '2026-08-13');
      expect(e2.calories, closeTo(e.calories / 2, 0.01));
    });

    test('the ingredient breakdown scales too, so you know what to plate', () {
      final Meal m = _batch(saved: true);
      final MealPortion p = MealMath.byCookedGrams(m, 400); // a fifth
      expect(p.breakdown.length, 2);
      final IngredientPortion chicken = p.breakdown
          .firstWhere((IngredientPortion i) => i.name == 'Chicken breast');
      expect(chicken.grams, closeTo(750 * 0.2, 0.01));
    });
  });
}
