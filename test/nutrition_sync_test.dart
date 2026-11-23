import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/food.dart';
import 'package:bodycomp/nutrition_sync.dart';

// A fixed "now" so the 60-day window is the same every run.
final DateTime _now = DateTime(2026, 6, 30, 14, 5);

FoodEntry _entry(String id, String date, double cal, double p, double f,
        double c) =>
    FoodEntry(
        id: id,
        date: date,
        name: id,
        serving: '100 g',
        calories: cal,
        protein: p,
        fat: f,
        carbs: c);

final List<FoodEntry> _foods = <FoodEntry>[
  _entry('eggs', '2026-06-29', 150, 13, 11, 1),
  _entry('toast', '2026-06-29', 130, 4, 2, 24),
  _entry('apple', '2026-06-28', 95, 0, 0, 25),
  // 61 days before 2026-06-30: outside the window.
  _entry('old', '2026-04-30', 500, 30, 20, 40),
  // Exactly 60 days before: the first date still inside.
  _entry('edge', '2026-05-01', 400, 25, 10, 50),
];

void main() {
  group('per-day record', () {
    test('sums the date into one record with a local-day window', () {
      final NutritionDay d = nutritionDayFor(_foods, '2026-06-29');
      expect(d.calories, 280);
      expect(d.protein, 17);
      expect(d.fat, 13);
      expect(d.carbs, 25);
      expect(d.isEmpty, isFalse);
      expect(d.start, DateTime(2026, 6, 29));
      expect(d.end, DateTime(2026, 6, 29, 23, 59, 59));
      expect(d.end.isAfter(d.start), isTrue);
      expect(d.end.day, d.start.day);
    });

    test('stamp rounds so float noise is not a change', () {
      expect(nutritionStamp(280.0000001, 16.6, 13.4, 25), '280|17|13|25');
      expect(nutritionDayFor(_foods, '2026-06-29').stamp, '280|17|13|25');
    });
  });

  group('which dates need syncing', () {
    test('every date with food inside the window when nothing is written',
        () {
      final List<NutritionDay> todo = nutritionDaysToSync(_foods,
          written: <String, String>{}, now: _now);
      expect(todo.map((NutritionDay d) => d.date).toList(),
          <String>['2026-05-01', '2026-06-28', '2026-06-29']);
      expect(todo.every((NutritionDay d) => !d.isEmpty), isTrue);
    });

    test('skips a date whose stamp matches, keeps one that moved', () {
      final List<NutritionDay> todo = nutritionDaysToSync(_foods,
          written: <String, String>{
            '2026-06-29': '280|17|13|25', // current
            '2026-06-28': '90|0|0|25', // stale
            '2026-05-01': '400|25|10|50', // current
          },
          now: _now);
      expect(todo.map((NutritionDay d) => d.date).toList(),
          <String>['2026-06-28']);
      expect(todo.single.calories, 95);
    });

    test('onlyDates narrows the sweep', () {
      final List<NutritionDay> todo = nutritionDaysToSync(_foods,
          onlyDates: <String>{'2026-06-28'},
          written: <String, String>{},
          now: _now);
      expect(todo.map((NutritionDay d) => d.date).toList(),
          <String>['2026-06-28']);
    });

    test('a date outside the window is never synced, even when asked', () {
      final List<NutritionDay> todo = nutritionDaysToSync(_foods,
          onlyDates: <String>{'2026-04-30'},
          written: <String, String>{},
          now: _now);
      expect(todo, isEmpty);
    });

    test('a date emptied of food is a delete only when something was written',
        () {
      final List<NutritionDay> gone = nutritionDaysToSync(_foods,
          onlyDates: <String>{'2026-06-27'},
          written: <String, String>{'2026-06-27': '600|40|20|50'},
          now: _now);
      expect(gone.single.date, '2026-06-27');
      expect(gone.single.isEmpty, isTrue);

      final List<NutritionDay> never = nutritionDaysToSync(_foods,
          onlyDates: <String>{'2026-06-27'},
          written: <String, String>{},
          now: _now);
      expect(never, isEmpty);
    });
  });

  group('changed dates between saves', () {
    test('an edit, an addition and a removal each flag their date', () {
      final List<FoodEntry> after = <FoodEntry>[
        _entry('eggs', '2026-06-29', 150, 13, 11, 1),
        // toast removed: 06-29 total moves.
        _entry('apple', '2026-06-28', 95, 0, 0, 25), // unchanged
        _entry('old', '2026-04-30', 500, 30, 20, 40), // unchanged
        // edge removed entirely: 05-01 now empty.
        _entry('new', '2026-06-30', 300, 20, 10, 30), // new date
      ];
      expect(changedNutritionDates(_foods, after),
          <String>{'2026-06-29', '2026-05-01', '2026-06-30'});
    });

    test('moving an entry inside a day changes nothing', () {
      final List<FoodEntry> after = _foods
          .map((FoodEntry e) => FoodEntry(
              id: e.id,
              date: e.date,
              time: '12:00',
              name: e.name,
              serving: e.serving,
              calories: e.calories,
              protein: e.protein,
              fat: e.fat,
              carbs: e.carbs))
          .toList();
      expect(changedNutritionDates(_foods, after), isEmpty);
    });
  });

  group('ledger', () {
    test('round-trips and prunes dates that left the window', () {
      final Map<String, String> ledger = <String, String>{
        '2026-06-29': '280|17|13|25',
        '2026-05-01': '400|25|10|50',
        '2026-04-30': '500|30|20|40',
      };
      final String raw = encodeNutritionLedger(ledger, _now);
      final Map<String, dynamic> stored =
          jsonDecode(raw) as Map<String, dynamic>;
      expect(stored.keys.toSet(), <String>{'2026-06-29', '2026-05-01'});
      expect(decodeNutritionLedger(raw), <String, String>{
        '2026-06-29': '280|17|13|25',
        '2026-05-01': '400|25|10|50',
      });
    });

    test('anything unreadable is an empty ledger', () {
      expect(decodeNutritionLedger(''), isEmpty);
      expect(decodeNutritionLedger('not json'), isEmpty);
      expect(decodeNutritionLedger('[1,2]'), isEmpty);
      expect(decodeNutritionLedger('{"2026-06-29": 5}'), isEmpty);
    });
  });
}
