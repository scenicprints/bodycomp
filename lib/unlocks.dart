import 'goals.dart';

// ═══════════════════════════════════════════════════════════════════════
// UNLOCKS — what levelling up actually gets you. Cosmetics restyle the app,
// features open new screens, and content (boss battles, knowledge cards)
// keeps arriving. Everything is gated purely on level, so it can't be gamed,
// and every unlock is a real change the user can see.
// ═══════════════════════════════════════════════════════════════════════

enum UnlockKind { celebration, cardStyle, chartSkin, shelf, feature }

class Unlock {
  final String id;
  final String name;
  final String desc;
  final String emoji;
  final UnlockKind kind;
  final int level;
  const Unlock(
      this.id, this.name, this.desc, this.emoji, this.kind, this.level);
}

const List<Unlock> kUnlocks = <Unlock>[
  // celebrations
  Unlock('cel_confetti', 'Confetti', 'The classic burst', '🎉',
      UnlockKind.celebration, 1),
  Unlock('cel_fireworks', 'Fireworks', 'Bursts that bloom outward', '🎆',
      UnlockKind.celebration, 5),
  Unlock('cel_gold', 'Gold Shower', 'It rains gold', '🪙',
      UnlockKind.celebration, 10),
  Unlock('cel_accent', 'Signature', 'Your accent colour, falling', '✨',
      UnlockKind.celebration, 16),
  // card styles
  Unlock('card_classic', 'Classic Cards', 'Clean and flat', '▫️',
      UnlockKind.cardStyle, 1),
  Unlock('card_glass', 'Glass Cards', 'Frosted and translucent', '🫧',
      UnlockKind.cardStyle, 4),
  Unlock('card_gradient', 'Gradient Cards', 'A wash of your accent', '🌈',
      UnlockKind.cardStyle, 8),
  Unlock('card_minimal', 'Minimal Cards', 'Hairlines, no fill', '➖',
      UnlockKind.cardStyle, 12),
  // chart skins
  Unlock('chart_classic', 'Classic Chart', 'The standard trend line', '📈',
      UnlockKind.chartSkin, 1),
  Unlock('chart_glow', 'Glow Chart', 'A lit trend line', '💡',
      UnlockKind.chartSkin, 7),
  Unlock('chart_filled', 'Filled Chart', 'Gradient under the curve', '🏔️',
      UnlockKind.chartSkin, 11),
  // shelves
  Unlock('shelf_plain', 'Plain Shelf', 'Simple chips', '🗂️',
      UnlockKind.shelf, 1),
  Unlock('shelf_framed', 'Framed Shelf', 'Each win in its own frame', '🖼️',
      UnlockKind.shelf, 9),
  Unlock('shelf_cabinet', 'Trophy Cabinet', 'A lit display case', '🏛️',
      UnlockKind.shelf, 17),
  // features
  Unlock('f_boss', 'Boss Battles', 'Big multi-week challenges', '👹',
      UnlockKind.feature, 5),
  Unlock('f_monthly', 'Deeper Coach', 'A monthly review from your coach', '🧠',
      UnlockKind.feature, 6),
  Unlock('f_stats', 'Advanced Stats', 'Rates, projections, correlations', '📊',
      UnlockKind.feature, 9),
  Unlock('f_certs', 'Certificates', 'A keepsake for the big wins', '📜',
      UnlockKind.feature, 11),
  Unlock('f_recap', 'Year in Review', 'Your journey recapped and exportable',
      '📅', UnlockKind.feature, 13),
  Unlock('f_titles', 'Title Selection', 'Wear any rank you have earned', '🎖️',
      UnlockKind.feature, 14),
];

bool hasUnlock(String id, int level) {
  for (final Unlock u in kUnlocks) {
    if (u.id == id) return level >= u.level;
  }
  return false;
}

List<Unlock> unlocksOfKind(UnlockKind k, int level) =>
    kUnlocks.where((Unlock u) => u.kind == k && u.level <= level).toList();

/// The next thing to look forward to, or null once everything is unlocked.
Unlock? nextUnlock(int level) {
  Unlock? best;
  for (final Unlock u in kUnlocks) {
    if (u.level > level && (best == null || u.level < best.level)) {
      best = u;
    }
  }
  return best;
}

/// The emblem worn beside the level — one per rank tier.
String insigniaFor(int level) {
  if (level >= 25) return '👑';
  if (level >= 18) return '💎';
  if (level >= 12) return '🛡️';
  if (level >= 7) return '⚔️';
  if (level >= 3) return '🔰';
  return '🌱';
}

/// Every rank earned so far, for Title Selection.
List<String> earnedTitles(int level) {
  final List<String> out = <String>['Rookie'];
  if (level >= 3) out.add('Rising');
  if (level >= 7) out.add('Committed');
  if (level >= 12) out.add('Veteran');
  if (level >= 18) out.add('Elite');
  if (level >= 25) out.add('Legend');
  return out;
}

// ── knowledge cards ─────────────────────────────────────────────────────

class KnowledgeCard {
  final String title;
  final String text;
  final String emoji;
  const KnowledgeCard(this.title, this.text, this.emoji);
}

/// Collected one per level — a small library that builds as you climb.
const List<KnowledgeCard> kKnowledge = <KnowledgeCard>[
  KnowledgeCard('Water weight lies',
      'Day-to-day scale swings are mostly water, glycogen and food in transit. A 7-day average is the only honest read.', '💧'),
  KnowledgeCard('Protein protects muscle',
      'In a deficit the body will burn muscle for fuel unless protein stays high. Roughly 1 g per lb of lean mass keeps it.', '🥩'),
  KnowledgeCard('A pound of fat',
      'About 3,500 calories. A 500/day deficit is roughly a pound a week, which is why patience beats severity.', '🔥'),
  KnowledgeCard('Fiber is satiety',
      'Fiber slows digestion and blunts the hunger that wrecks a deficit. It is the cheapest adherence tool there is.', '🥦'),
  KnowledgeCard('TDEE is an estimate',
      'Maintenance calories are a moving guess, not a fact. When the math and the trend disagree, trust the trend.', '📐'),
  KnowledgeCard('Sleep is a fat-loss tool',
      'Short sleep raises hunger hormones and drains willpower. Under six hours makes a deficit dramatically harder to hold.', '😴'),
  KnowledgeCard('NEAT quietly matters',
      'Fidgeting, walking and standing can swing hundreds of calories a day — and it all drops silently when you diet.', '🚶'),
  KnowledgeCard('Recomp is slow but real',
      'Losing fat while holding muscle makes the scale move less. Judge it by lean mass, not weight alone.', '🏗️'),
  KnowledgeCard('Easy runs build the engine',
      'Most aerobic gain comes from runs you could hold a conversation through. Going hard every time just banks fatigue.', '🏃'),
  KnowledgeCard('Resting heart rate is a scoreboard',
      'As aerobic fitness improves, resting HR falls. It is one of the few fitness metrics you cannot fake.', '❤️'),
  KnowledgeCard('Plateaus are usually adherence',
      'True metabolic stalls are rare. Far more often intake crept up or output crept down. Measure before cutting further.', '🪨'),
  KnowledgeCard('Refeeds have a purpose',
      'A planned higher-carb day restores glycogen and gives a mental break. Planned is the operative word.', '🍚'),
  KnowledgeCard('Muscle is metabolic',
      'Lean mass raises maintenance slightly, but its real value is the shape it gives you at the very same weight.', '💪'),
  KnowledgeCard('The last ten pounds are slower',
      'A smaller body burns fewer calories, so the same deficit yields less. Expect a taper rather than a stall.', '🐢'),
  KnowledgeCard('Consistency beats intensity',
      'A merely good plan followed for a year beats a perfect plan followed for three weeks. Every single time.', '🎯'),
  KnowledgeCard('Alcohol pauses fat burning',
      'The body prioritises clearing alcohol, and it carries 7 calories per gram with no nutrition attached.', '🍷'),
  KnowledgeCard('Weigh at the same time',
      'First thing, after the bathroom, before food. Consistent measurement is what makes a trend readable at all.', '⏰'),
  KnowledgeCard('Strength keeps the muscle',
      'Resistance training tells the body the muscle is needed. Without that signal a deficit takes fat and muscle both.', '🏋️'),
  KnowledgeCard('Hunger is not an emergency',
      'Appetite arrives in waves and passes. Sitting with mild hunger is a trainable skill, not a personality trait.', '🌊'),
  KnowledgeCard('Maintenance is its own skill',
      'Keeping weight off uses different habits than losing it. Practising maintenance is part of the goal, not the end of it.', '⚖️'),
];

List<KnowledgeCard> knowledgeFor(int level) =>
    kKnowledge.take(level.clamp(0, kKnowledge.length)).toList();

// ── prestige / seasons ──────────────────────────────────────────────────

/// Reaching the goal weight doesn't end the app — it prestiges into a
/// maintenance season with a star on the rank and its own goals.
class Prestige {
  final int count;
  final String? seasonStart; // 'YYYY-MM-DD'
  const Prestige(this.count, [this.seasonStart]);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'count': count,
        if (seasonStart != null) 'seasonStart': seasonStart,
      };
  factory Prestige.fromJson(Map<String, dynamic> j) => Prestige(
        (j['count'] as num?)?.toInt() ?? 0,
        j['seasonStart'] as String?,
      );

  bool get active => count > 0;
  String get stars => count <= 0 ? '' : '★' * count.clamp(0, 5);
}

// ── boss battles ────────────────────────────────────────────────────────

/// Big multi-week challenges — same machinery as a normal challenge, just
/// longer, worth far more, and gated behind the Boss Battles unlock.
const List<ChallengeDef> kBossBattles = <ChallengeDef>[
  ChallengeDef(
      id: 'boss_protein_30',
      title: 'The Protein Marathon',
      desc: 'Hit protein on 25 of the next 30 days',
      emoji: '👹',
      days: 30,
      xp: 1500,
      unlockLevel: 5,
      auto: true,
      cooldownDays: 30),
  ChallengeDef(
      id: 'boss_deficit_21',
      title: 'Three Weeks Sharp',
      desc: '18 deficit days out of 21',
      emoji: '🐉',
      days: 21,
      xp: 1200,
      unlockLevel: 7,
      auto: true,
      cooldownDays: 30),
  ChallengeDef(
      id: 'boss_run_12',
      title: 'The Grind',
      desc: '12 runs in 30 days',
      emoji: '🦾',
      days: 30,
      xp: 1500,
      unlockLevel: 9,
      auto: true,
      cooldownDays: 30),
  ChallengeDef(
      id: 'boss_perfect_14',
      title: 'Flawless Fortnight',
      desc: '14 straight qualifying days',
      emoji: '🔱',
      days: 14,
      xp: 1200,
      unlockLevel: 11,
      auto: true,
      cooldownDays: 21),
];

// ── goal insight (the tap-through detail) ───────────────────────────────

class GoalInsight {
  final String what;
  final String why;
  final String how;
  final String watch;
  const GoalInsight(this.what, this.why, this.how, this.watch);
}

/// Real coaching for one goal — what it is, why it moves the needle, how to
/// get there from where the user actually is, and the trap to avoid.
GoalInsight goalInsight(Goal g, GoalState st, {int deficit = 500}) {
  final double lbToGo = st.currentWeight - st.goalWeight;
  final String weeks = deficit > 0
      ? (lbToGo * 3500 / (deficit * 7)).abs().round().toString()
      : '—';
  switch (g.lane) {
    case Lane.weight:
      if (g.id == 'w_new_low') {
        return const GoalInsight(
          'A weigh-in lower than any you have logged before.',
          'New lows are the cleanest proof the trend is real. Unlike one good morning, an all-time low can only happen if you are genuinely heading down.',
          'It fires on its own the moment the scale reads a new bottom. Weigh at the same time each morning so the comparison stays fair.',
          'You will not set one every week, and that is normal — water can mask real fat loss for ten days at a stretch.',
        );
      }
      if (g.id == 'w_goal') {
        return GoalInsight(
          'The finish line: your target body fat, expressed as a weight.',
          'This is the point of everything else. Every checkpoint below it exists to make this one feel reachable.',
          'Roughly $weeks weeks at your current deficit. Nothing about the method changes — you simply keep doing it.',
          'The last stretch runs slower because a lighter body burns less. Expect a taper instead of assuming something broke.',
        );
      }
      if (g.id == 'w_halfway') {
        return const GoalInsight(
          'The midpoint between your starting weight and your goal.',
          'Halfway is the psychological hinge of a cut. Past it, what is left is smaller than what you have already proven you can do.',
          'Keep the deficit steady. This is not the moment to get aggressive, it is the moment to get repeatable.',
          'Motivation often dips right after a big milestone. Decide what next week looks like before you get here.',
        );
      }
      return GoalInsight(
        'Your next weight checkpoint on the way down.',
        'Round-number checkpoints keep a win about two weeks out instead of months away, so payoff arrives before motivation fades.',
        'At a $deficit-calorie daily deficit that is roughly a pound a week. Protein is the lever — hold your target and the loss comes off as fat, not muscle.',
        'The scale can swing several pounds on water alone. Judge this by the 7-day average, never a single morning.',
      );
    case Lane.body:
      if (g.id == 'b_muscle_intact') {
        return const GoalInsight(
          'Lose fat across a month while lean mass holds steady.',
          'This is the difference between losing weight and improving your body — same scale number, completely different outcome.',
          'Keep protein at target and keep resistance work in your week. Those two things are what tell the body to hold the muscle.',
          'Lean-mass readings are noisy day to day. This judges a month, so do not react to one bad scan.',
        );
      }
      if (g.id == 'b_built_different') {
        return const GoalInsight(
          'Gain lean mass while fat mass falls — true recomposition.',
          'The hardest and most valuable outcome in the whole app. It means you are reshaping, not merely shrinking.',
          'A slightly smaller deficit, protein high, and progressive resistance training. Recomp needs both fuel and a stimulus.',
          'It is slow and it will not happen every month. Treat it as a bonus rather than a monthly expectation.',
        );
      }
      return const GoalInsight(
        'The next body-fat mark on the way to your target.',
        'Body fat is the honest metric — it separates real fat loss from water and muscle in a way the scale simply cannot.',
        'Same fundamentals as the weight lane: a steady deficit and protein at target. Body fat follows fat mass down.',
        'Body-fat readings are less precise than weight. Watch direction across weeks, not the exact number on any one day.',
      );
    case Lane.running:
      if (g.id == 'r_the_5k') {
        return const GoalInsight(
          'Thirty minutes of continuous running — a full 5K.',
          'The headline goal of the trainer, and it builds the aerobic base that makes every other kind of training easier.',
          'Climb the ladder. Each rung adds a little running and removes a little walking, and the plan advances you when your heart rate says you are ready.',
          'Do not skip rungs because one day felt good. Rushed progression is the quickest route to a shin splint.',
        );
      }
      if (g.id == 'r_pb') {
        return const GoalInsight(
          'Go further in a single run than you ever have.',
          'Distance records prove the aerobic engine is growing, and they re-fire forever — there is always another one.',
          'Add distance slowly, roughly ten percent a week, and keep the effort easy. Long and slow builds the base.',
          'Attempting a record on tired legs or short sleep usually just feels awful. Pick a day you are fresh.',
        );
      }
      if (g.id == 'r_cruise') {
        return const GoalInsight(
          'Finish a run inside your easy aerobic zone.',
          'Most fitness comes from runs that feel comfortable. Holding an easy pace is the skill that lets you run more often.',
          'Slow down more than feels natural — heart rate should sit near your walking rate plus a modest margin. Walk breaks are fine.',
          'Ego is the enemy here. If you cannot hold a conversation, you are running too hard for this one.',
        );
      }
      return const GoalInsight(
        'The next step in your running progression.',
        'Running accelerates fat loss and, more importantly, builds a habit that outlives any diet.',
        'Show up more than you push. Frequency at an easy effort beats occasional hard sessions for fitness and consistency both.',
        'Two hard days back to back is how injuries begin. Keep most runs easy and let the plan level you up.',
      );
    case Lane.nutrition:
      return const GoalInsight(
        'A weekly nutrition target — it resets every week, so it is always live.',
        'Nutrition is where fat loss is actually won. Hitting protein and staying in a deficit are the two behaviours that decide the outcome.',
        'Anchor every meal with a protein source first and build around it. Prep in batches so the easy choice is the right one.',
        'Perfection is not required — the target allows misses. Chasing a flawless week usually ends in abandoning the whole thing.',
      );
    case Lane.consistency:
      return const GoalInsight(
        'Showing up: logging your days and keeping the chain alive.',
        'Consistency predicts whether someone reaches their goal better than diet choice or training style ever will.',
        'Log at the same moment each day until it is automatic. A day only needs food logged and protein hit to count.',
        'One missed day never breaks a streak here, and earned freezes cover a second. Missing is not failing — quitting is.',
      );
    case Lane.sleep:
      return const GoalInsight(
        'Getting genuine, sufficient sleep on a regular basis.',
        'Sleep quietly governs hunger, willpower and recovery. Short sleep makes a deficit feel far harder than it needs to.',
        'Aim for seven hours or more. A consistent bedtime does more good than any single night of catch-up.',
        'Do not chase the number after one bad night — that is normal. It is repeated short nights that undo progress.',
      );
  }
}
