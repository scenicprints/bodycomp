import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:bodycomp/main.dart';
import 'package:bodycomp/food.dart';
import 'package:bodycomp/advisor.dart';

void main() {
  group('AdvisorDigest', () {
    test('includes goal, targets, and the day\'s food in the digest', () {
      final String today = formatDate(DateTime.now());
      final UserCalibration cal = UserCalibration(
          startWeight: 200, startBf: 0.25, targetBf: 0.15, deficit: 500);
      final List<DailyLog> logs = <DailyLog>[
        DailyLog(date: today, weight: 198, bf: 0.24),
      ];
      final List<FoodEntry> foods = <FoodEntry>[
        FoodEntry(
            id: 'a',
            date: today,
            name: 'Oatmeal',
            serving: '100 g',
            calories: 380,
            protein: 13,
            fat: 7,
            carbs: 67,
            nutrients: <String, double>{'fiber': 10}),
      ];

      final String d =
          AdvisorDigest.build(cal, logs, foods, <String>{}, 'daily');
      expect(d, contains('DATE:'));
      expect(d, contains('GOAL:'));
      expect(d, contains('DAILY TARGETS:'));
      expect(d, contains('PER-DAY DETAIL'));
      expect(d, contains('Oatmeal'));
      expect(d, contains('380cal'));
    });

    test('a fasted day shows as FASTED in the digest', () {
      final String today = formatDate(DateTime.now());
      final UserCalibration cal =
          UserCalibration(startWeight: 200, startBf: 0.25, targetBf: 0.15);
      final String d = AdvisorDigest.build(
          cal,
          <DailyLog>[DailyLog(date: today, weight: 199, bf: 0.24)],
          <FoodEntry>[],
          <String>{today},
          'daily');
      expect(d, contains('FASTED'));
    });
  });

  group('AdvisorInsight', () {
    test('round-trips through JSON', () {
      final AdvisorInsight i = AdvisorInsight(
          kind: 'weekly',
          periodKey: '2026-06-22',
          text: 'Great week.',
          createdAtMs: 1700000000000);
      final AdvisorInsight back = AdvisorInsight.fromJson(
          jsonDecode(jsonEncode(i.toJson())) as Map<String, dynamic>);
      expect(back.kind, 'weekly');
      expect(back.periodKey, '2026-06-22');
      expect(back.text, 'Great week.');
      expect(back.createdAtMs, 1700000000000);
    });

    test('model list + default are sane', () {
      expect(kDefaultAdvisorModel, 'claude-opus-4-8');
      expect(advisorModelLabel('claude-haiku-4-5'), contains('Haiku'));
      expect(kAdvisorModels.length, 3);
    });
  });
}
