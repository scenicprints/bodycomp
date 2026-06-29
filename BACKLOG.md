# BodyComp — Backlog & Roadmap

Living plan for the big build-out. Shipped today: **v1.1.2** (OTA updates, body-comp
tracker, food journal with USDA-primary + Open Food Facts fallback).

## How we work
- `main` = the last **shipped** release. Big work happens on a **feature branch**.
- **One release per batch**, not per change. Each big batch gets its own detailed
  plan + sign-off before building.
- Data-model changes are **additive and migration-safe** — never wipe existing
  logs/settings. (In-place OTA updates already preserve data.)

---

## Batch 1 — Food Tab v2: intuitive + budgeted  → v1.2.0  ✅ SHIPPED
Polish the food experience and make the day view feel like the reference screenshot.
*(Deferred to a later pass: the full hour-by-hour timeline — Batch 1 groups by meal period
instead. Macro-target rings are horizontal bars for now.)*

- **Budget header** — calorie + macro **rings/bars** at the top of the Food tab
  showing consumed vs target (the MacroFactor-style indicator). *(req #1)*
- **Macro targets** — finally define them. Auto-derived defaults, editable in Settings:
  protein ≈ 1 g/lb lean mass, fat ≈ 0.3 g/lb body weight, carbs = remaining calories,
  fiber ≈ 14 g per 1000 kcal. Drives the rings.
- **Log food for future dates** — remove the "no future" block; useful for planning. *(req #1)*
- **Per-serving amounts** — choose "1 serving (30 g)" or "2 servings" as well as raw
  grams, when the source provides a serving size. *(your request)*
- **Move / copy a food to another day.** *(your request)*
- **Stricter search** — prioritize whole foods (USDA Foundation/SR Legacy) over the wall
  of branded variants, cap the result count, dedupe near-identical names. *(your request)*
- **UX/visual refresh** — cleaner cards with icons, optional time-of-day grouping.
- **Fasting vs. didn't-log** *(req #5)* — add a "mark day as fasted" action. A fasted day
  counts as a real 0-kcal day in the TDEE math; an unlogged day stays excluded (today's
  behavior). Small stored set of fasted dates.

**Risk:** mostly UI + light logic. Macro targets are heuristic (clearly labeled, editable).
Fasted-dates set is additive. **Low data risk.**

---

## Batch 2 — Meal Maker  → v1.3.0  *(tricky)*
Build a meal from ingredients (raw weights), then portion it by calories.

**The math (proposed):**
- Each ingredient = food + raw grams → its nutrition. Sum → **meal totals** (cal/macros).
  Cooking conserves calories/macros; only water weight changes.
- You weigh the **whole cooked dish** → cooked total grams.
- "I want **X calories** from this meal" → portion fraction `p = X / meal_total_cal`.
  → **grams of cooked meal to eat = p × cooked_total**, with the portion's full macros.
- Per-ingredient cooked grams (assuming the dish loses water uniformly):
  `p × raw_gramsᵢ × (cooked_total / Σ raw_grams)`.

**Open question:** the per-ingredient *cooked* breakdown assumes uniform shrink across
ingredients (we only know raw weights + one cooked total). Good enough, or do you want to
weigh ingredients individually after cooking? **Data model:** new saved `Meal` (recipe) +
meals that generate food-log entries. Additive.

---

## Batch 3 — Food Advisor  → v1.4.0
Coaching on how you're doing, tied to actual results.

- **Tier 1 (heuristic):** macro target adherence (e.g. "fiber low — 12 g vs 30 g goal",
  "carbs high"), trends, deficit vs. actual weight change.
- **Tier 2 (pattern detection):** correlate food patterns with weight outcomes
  ("you trend down on oatmeal-breakfast days"; "weeks with popsicles lost less than your
  deficit predicted"). Lightweight stats over your log — needs enough data, framed as
  *correlation, not proof.*

**Open question:** on-device heuristics only, or also a natural-language coach powered by
an LLM (smarter phrasing/insights, but needs an API key + per-use cost)? **Data:** read-only
over existing logs; relies on Batch 1's targets + fasting fix for accuracy.

---

## Batch 4 — 5K Trainer  → v1.5.0
Couch-to-5K that's aware of your weight loss + fueling. (You're injured/no lifting, running now.)

- Progressive run/walk plan → 5K, paced for "barely able to run today."
- **Log runs** (distance, time, pace) — likely its own tab.
- Integration: fueling/recovery notes tied to your deficit; sanity-check that running +
  a steep deficit isn't stalling recovery.

**Open questions:** how to capture runs — manual entry, in-app GPS tracking, or import from
a watch/Health Connect? How cautious given the injury? **Data model:** new run/workout type.

---

## Batch 5 — Sleep import  → v1.6.0  *(needs discovery)*
You charge watch+phone on a dock while sleeping and sleep with a partner — so wrist/bed
tracking won't work for you. Realistic options:
- **Health Connect** (Android's health hub) **if** some device already records your sleep
  and syncs there — then we just read it. Needs to know your watch/phone ecosystem.
- **Manual entry** (bed/wake time) as the reliable fallback.

**Open question:** what watch/phone do you have, and does anything currently record your
sleep at all? That decides whether import is even possible vs. manual-only.

---

## Sequencing rationale
Batch 1 first because the budget rings, fasting fix, and targets are the **foundation** the
Food Advisor (Batch 3) needs to be accurate, and they make daily use pleasant now. Meal
Maker, Advisor, 5K Trainer, and Sleep are independent enough to reorder by what you want most.
