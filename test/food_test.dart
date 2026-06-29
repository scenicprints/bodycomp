import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/food.dart';

// A realistic Open Food Facts "nutriments" block (per-100g, OFF's gram units).
Map<String, dynamic> _ground = <String, dynamic>{
  'product_name': 'Ground Beef 80/20',
  'brands': 'Acme',
  'serving_size': '4 oz (113 g)',
  'nutriments': <String, dynamic>{
    'energy-kcal_100g': 254,
    'proteins_100g': 17,
    'fat_100g': 20,
    'carbohydrates_100g': 0,
    'saturated-fat_100g': 7.5,
    'sodium_100g': 0.075, // g -> 75 mg
    'cholesterol_100g': 0.08, // g -> 80 mg
    'calcium_100g': 0.018, // g -> 18 mg
    'iron_100g': 0.0023, // g -> 2.3 mg
    'vitamin-d_100g': 0.0000005, // g -> 0.5 µg
  },
};

void main() {
  group('Open Food Facts parsing', () {
    test('parses macros and converts micronutrient units', () {
      final FoodTemplate? t = OpenFoodFacts.parseProduct(_ground, '123');
      expect(t, isNotNull);
      expect(t!.name, 'Ground Beef 80/20 (Acme)');
      expect(t.kcal100, 254);
      expect(t.protein100, 17);
      expect(t.fat100, 20);
      expect(t.nutrients100['sodium'], closeTo(75, 1e-6));
      expect(t.nutrients100['cholesterol'], closeTo(80, 1e-6));
      expect(t.nutrients100['calcium'], closeTo(18, 1e-6));
      expect(t.nutrients100['iron'], closeTo(2.3, 1e-6));
      expect(t.nutrients100['vitaminD'], closeTo(0.5, 1e-9));
      expect(t.servingGrams, closeTo(113, 1e-6));
    });

    test('scales correctly to a chosen serving in grams', () {
      final FoodTemplate t = OpenFoodFacts.parseProduct(_ground, '123')!;
      final FoodEntry e =
          t.toEntry(id: 'x', date: '2026-06-29', grams: 200, source: 'barcode');
      expect(e.calories, closeTo(508, 1e-6)); // 254 * 2
      expect(e.fat, closeTo(40, 1e-6));
      expect(e.nutrients['sodium'], closeTo(150, 1e-6)); // 75 * 2
      expect(e.serving, '200 g');
    });

    test('falls back from kJ when kcal is absent', () {
      final Map<String, dynamic> kjOnly = <String, dynamic>{
        'product_name': 'Juice',
        'nutriments': <String, dynamic>{'energy_100g': 418.4, 'sugars_100g': 10},
      };
      final FoodTemplate? t = OpenFoodFacts.parseProduct(kjOnly, null);
      expect(t, isNotNull);
      expect(t!.kcal100, closeTo(100, 1e-6)); // 418.4 / 4.184
    });

    test('returns null when there is no calorie data', () {
      final Map<String, dynamic> noCal = <String, dynamic>{
        'product_name': 'Water',
        'nutriments': <String, dynamic>{},
      };
      expect(OpenFoodFacts.parseProduct(noCal, null), isNull);
    });
  });

  group('USDA FoodData Central parsing', () {
    // A foods/search "food" object for raw onion (per 100 g).
    final Map<String, dynamic> onion = <String, dynamic>{
      'description': 'Onions, raw',
      'dataType': 'Foundation',
      'servingSize': 100,
      'servingSizeUnit': 'g',
      'foodNutrients': <dynamic>[
        <String, dynamic>{'nutrientNumber': '208', 'unitName': 'KCAL', 'value': 40},
        <String, dynamic>{'nutrientNumber': '203', 'unitName': 'G', 'value': 1.1},
        <String, dynamic>{'nutrientNumber': '204', 'unitName': 'G', 'value': 0.1},
        <String, dynamic>{'nutrientNumber': '205', 'unitName': 'G', 'value': 9.34},
        <String, dynamic>{'nutrientNumber': '291', 'unitName': 'G', 'value': 1.7},
        <String, dynamic>{'nutrientNumber': '307', 'unitName': 'MG', 'value': 4},
        <String, dynamic>{'nutrientNumber': '401', 'unitName': 'MG', 'value': 7.4},
        <String, dynamic>{'nutrientNumber': '320', 'unitName': 'UG', 'value': 2},
      ],
    };

    test('parses a whole food with correct units', () {
      final FoodTemplate? t = Usda.parseFood(onion);
      expect(t, isNotNull);
      expect(t!.name, 'Onions, raw');
      expect(t.kcal100, 40);
      expect(t.protein100, closeTo(1.1, 1e-9));
      expect(t.carbs100, closeTo(9.34, 1e-9));
      expect(t.nutrients100['fiber'], closeTo(1.7, 1e-9));
      expect(t.nutrients100['sodium'], closeTo(4, 1e-9)); // 4 mg
      expect(t.nutrients100['vitaminC'], closeTo(7.4, 1e-9)); // 7.4 mg
      expect(t.nutrients100['vitaminA'], closeTo(2, 1e-9)); // 2 µg
      expect(t.servingGrams, closeTo(100, 1e-9));
    });

    test('appends brand and keeps barcode for branded foods', () {
      final Map<String, dynamic> branded = <String, dynamic>{
        'description': 'Protein Bar',
        'brandName': 'Acme',
        'gtinUpc': '012345678905',
        'foodNutrients': <dynamic>[
          <String, dynamic>{'nutrientNumber': '208', 'unitName': 'KCAL', 'value': 350},
          <String, dynamic>{'nutrientNumber': '203', 'unitName': 'G', 'value': 30},
        ],
      };
      final FoodTemplate? t = Usda.parseFood(branded, barcode: '012345678905');
      expect(t!.name, 'Protein Bar (Acme)');
      expect(t.barcode, '012345678905');
      expect(t.protein100, 30);
    });

    test('returns null without energy data', () {
      final Map<String, dynamic> noCal = <String, dynamic>{
        'description': 'Mystery',
        'foodNutrients': <dynamic>[
          <String, dynamic>{'nutrientNumber': '203', 'unitName': 'G', 'value': 5}
        ],
      };
      expect(Usda.parseFood(noCal), isNull);
    });
  });

  group('search dedupe', () {
    FoodTemplate mk(String n) => FoodTemplate(
        name: n,
        kcal100: 1,
        protein100: 0,
        fat100: 0,
        carbs100: 0,
        nutrients100: <String, double>{});

    test('collapses near-identical names and caps the count', () {
      final List<FoodTemplate> out = FoodLookup.dedupe(<FoodTemplate>[
        mk('Onion'),
        mk('onion'),
        mk('Onion, raw'),
        mk('Onion'),
      ], cap: 10);
      expect(out.length, 2); // "onion" collapses, "onion, raw" distinct
      expect(FoodLookup.dedupe(<FoodTemplate>[mk('a'), mk('b'), mk('c')], cap: 2)
          .length, 2);
    });
  });

  group('meal maker', () {
    FoodTemplate ft(String n, double kcal, double p, double f, double c) =>
        FoodTemplate(
            name: n,
            kcal100: kcal,
            protein100: p,
            fat100: f,
            carbs100: c,
            nutrients100: <String, double>{'fiber': 1});
    Meal meal() => Meal(id: 'm', name: 'Rice & Chicken', ingredients: <MealIngredient>[
          MealIngredient(food: ft('Rice', 130, 2.7, 0.3, 28), rawGrams: 200),
          MealIngredient(food: ft('Chicken', 165, 31, 3.6, 0), rawGrams: 150),
        ]);

    test('totals sum the ingredients', () {
      final Meal m = meal();
      expect(m.totalGrams, 350);
      expect(m.calories, closeTo(507.5, 1e-6));
      expect(m.protein, closeTo(51.9, 1e-6));
      expect(m.nutrients['fiber'], closeTo(3.5, 1e-6)); // 2.0 + 1.5
    });

    test('portion by calories scales the whole meal + breakdown', () {
      final MealPortion pr = MealMath.byCalories(meal(), 253.75);
      expect(pr.fraction, closeTo(0.5, 1e-9));
      expect(pr.grams, closeTo(175, 1e-6));
      expect(pr.protein, closeTo(25.95, 1e-6));
      expect(pr.breakdown[0].grams, closeTo(100, 1e-6)); // rice
      expect(pr.breakdown[1].grams, closeTo(75, 1e-6)); // chicken
    });

    test('portion by grams gives the calories', () {
      expect(MealMath.byGrams(meal(), 175).calories, closeTo(253.75, 1e-6));
    });

    test('round-trips through JSON', () {
      final Meal back = Meal.fromJson(
          jsonDecode(jsonEncode(meal().toJson())) as Map<String, dynamic>);
      expect(back.name, 'Rice & Chicken');
      expect(back.calories, closeTo(507.5, 1e-6));
      expect(back.ingredients.length, 2);
    });
  });

  group('day rollups', () {
    test('totals and caloriesByDate sum a day across entries', () {
      final List<FoodEntry> foods = <FoodEntry>[
        FoodEntry(
            id: 'a',
            date: '2026-06-29',
            name: 'Eggs',
            serving: '100 g',
            calories: 150,
            protein: 13,
            fat: 11,
            carbs: 1,
            nutrients: <String, double>{'sodium': 140}),
        FoodEntry(
            id: 'b',
            date: '2026-06-29',
            name: 'Toast',
            serving: '50 g',
            calories: 130,
            protein: 4,
            fat: 2,
            carbs: 24,
            nutrients: <String, double>{'fiber': 3, 'sodium': 200}),
        FoodEntry(
            id: 'c',
            date: '2026-06-28',
            name: 'Apple',
            serving: '180 g',
            calories: 95,
            protein: 0,
            fat: 0,
            carbs: 25),
      ];
      final DayTotals d = FoodMath.totals(foods, '2026-06-29');
      expect(d.calories, 280);
      expect(d.protein, 17);
      expect(d.nutrients['sodium'], 340);
      expect(d.nutrients['fiber'], 3);

      final Map<String, double> byDate = FoodMath.caloriesByDate(foods);
      expect(byDate['2026-06-29'], 280);
      expect(byDate['2026-06-28'], 95);
    });
  });
}
