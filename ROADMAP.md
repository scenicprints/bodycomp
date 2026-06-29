# BodyComp — Roadmap & Continuity Guide

> **Purpose:** this file is the single source of truth for picking the project back up
> in a brand-new chat (e.g. if we run out of tokens). It explains what's built, how to
> ship updates, how the code is organized, the non-obvious gotchas, and a **detailed plan
> for every remaining feature**. Read this top-to-bottom and you can continue cold.
>
> `BACKLOG.md` is the short version; this is the detailed version.

---

## 1. What the app is

**BodyComp** is a personal Android body-recomposition tracker (Flutter), used by one person
(GitHub user **scenicprints**). It started as a single `main.dart` from flutlab.io and was
rebuilt into a real Flutter project with **over-the-air updates**. Core ideas:

- Track weight + body-fat % over time → lean mass, fat mass, adaptive TDEE, goal projection.
- A **food journal** (barcode / name search / manual) that feeds the calorie side of the TDEE math.
- A **Cook tab** that portions home-cooked meals by calories, accounting for cooked weight.
- It updates itself: you push a release, the phone pulls it with one tap.

---

## 2. Current status

**Latest shipped version: v1.4.0** (`pubspec.yaml` `version:` is the source of truth — currently `1.4.0+9`).

Release history (each is a GitHub Release with a signed APK):
| Version | What shipped |
|---|---|
| 1.0.0 | Initial real project + OTA self-updater |
| 1.0.1 | TDEE fixes (ignore calorie-less days; smooth baseline over 7-day lean mass) |
| 1.0.2 | **Fixed OTA install crash** (added the `ota_update` FileProvider) |
| 1.1.0 | Food Journal: barcode scan → Open Food Facts, extended nutrients |
| 1.1.1 | Fixed scanner crash (explicit controller); added search-by-name |
| 1.1.2 | **USDA FoodData Central** as primary food source, OFF fallback |
| 1.2.0 | Food Tab v2: budget bars, macro targets, future logging, per-serving, move/copy, meal grouping, fasting-vs-didn't-log |
| 1.3.0 | Meal Maker (saved-meal library) + nav-bar bottom-sheet fix |
| 1.4.0 | **Cook tab** (cooked-weight calculator + 24h leftovers), hourly food log, linked Grams↔Servings, date+time move/copy |

---

## 3. How to develop & ship  ⚠️ READ THIS FIRST

### Environment (on the dev machine)
- **Flutter 3.44.2 + Dart 3.12** are installed. **There is NO Android SDK** on this machine —
  so you **cannot build an APK locally**. All APK builds happen in **GitHub Actions (cloud)**.
- **JDK 17 (Temurin)** is installed only so `keytool` could generate the signing key.
- **GitHub CLI (`gh`)** is installed and authenticated as `scenicprints`.
- You CAN run locally: `flutter analyze` and `flutter test` (headless). Always do this before shipping.
- Shell: Windows. Use **Git Bash** for anything that pipes raw bytes (see secrets gotcha);
  PowerShell is fine for most `gh`/`git` commands. `gh`/`git` need `$env:Path` refreshed in new
  PowerShell sessions: `$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")`.

### Repo & workflow
- Repo: **https://github.com/scenicprints/bodycomp** (PUBLIC — so the in-app updater needs no token).
- **`main` = the last shipped release.** Do big work on a **feature branch**, merge to `main` when done.
- **Work in large batches, one release per batch** (the user's explicit preference). Don't ship a
  release per tiny change. Only ask the user to update-and-test mid-batch when something needs a
  real device (camera, install). Otherwise verify with `flutter analyze` + `flutter test`.

### Publishing a release (the whole pipeline)
1. Bump `version:` in `pubspec.yaml` (e.g. `1.5.0+10` — the `+N` build number MUST increase or
   Android refuses the update).
2. Commit, then create an **annotated tag `vX.Y.Z`** whose message is the "What's New" notes.
   - ⚠️ PowerShell mangles multi-line/`()`-containing tag messages. Write notes to a temp file and
     use `git tag -a vX.Y.Z -F notesfile`.
3. `git push origin main` and `git push origin vX.Y.Z`.
4. The tag triggers **`.github/workflows/release.yml`**, which: sets up Flutter 3.44.2 + JDK 17,
   decodes the keystore from secrets, builds a signed APK with `--dart-define=USDA_API_KEY=...`,
   renames it `bodycomp-<version>.apk`, and publishes a GitHub Release with the tag message as body.
5. Watch it: `gh run watch <run-id> -R scenicprints/bodycomp --exit-status`.
6. On the phone: **Settings → App Updates → Check → Download & Install**.

`publish.ps1` automates steps 1–3 (it prompts for version + notes). It works, but for multi-line
notes the `-F` file approach above is more reliable.

### Signing keystore  ⚠️ IRREPLACEABLE
- All builds are signed with ONE key so Android allows in-place updates. Lose it and installed
  phones can't update (they'd have to uninstall = lose data).
- Local: `android/app/upload-keystore.jks` + `android/key.properties` (both **gitignored**).
- CI: stored as GitHub **secrets** `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`.
  (`build.gradle.kts` reads `key.properties`; the workflow writes it from the secrets.)
- **Back up `upload-keystore.jks` + its password off-machine.** (Recoverable from the
  `KEYSTORE_BASE64` secret if the machine dies, but don't rely on that alone.)

### Secrets gotcha
Set secrets from **Git Bash with raw-byte stdin**, NOT a PowerShell pipe — PowerShell re-encodes
to UTF-16 and corrupts base64 (this cost a release). E.g.:
`"/c/Program Files/GitHub CLI/gh.exe" secret set KEYSTORE_BASE64 -R scenicprints/bodycomp < keystore.b64`
Simple string secrets via `gh secret set NAME --body "..."` are fine.

### USDA API key
Food search uses USDA FoodData Central. The key is the GitHub secret **`USDA_API_KEY`**, injected at
build via `--dart-define`. The app falls back to `DEMO_KEY` (rate-limited) if absent. If the key is
ever lost, get a new free one at https://fdc.nal.usda.gov/api-key-signup.html and re-set the secret.

### In-app updater
`lib/updater.dart` hits `api.github.com/repos/scenicprints/bodycomp/releases/latest`, compares the
tag to the installed `package_info` version, and installs the APK via the `ota_update` package.

---

## 4. Architecture / code map

Three Dart files:
- **`lib/main.dart`** (~4,000 lines) — everything UI + the math engine + storage. Sections are
  marked with `// ═══` banners: data models, MathEngine, MacroTargets, AppStorage, theme, the app
  shell + bottom nav, Dashboard, Food tab, Cook/Meal UI, Ledger, Settings.
- **`lib/food.dart`** — food data layer (no UI): `FoodEntry`, nutrient registry (`kNutrients`),
  `FoodTemplate`, Open Food Facts + USDA clients, `FoodLookup` (USDA-primary), and the meal model
  (`Meal`, `MealIngredient`, `cookingYield()`, `MealMath`).
- **`lib/updater.dart`** — the OTA updater service + UI card.

Tests: `test/tdee_test.dart`, `test/food_test.dart` (22 tests). They cover the **pure logic**
(TDEE, macro targets, fasting, Open Food Facts + USDA parsing, unit conversions, meal cooked-weight
portioning, JSON round-trips). UI isn't unit-tested — it's verified on-device after each batch.

### Data model & storage
All data is one JSON file in the app's private internal storage (`bodycomp_data.json`), via
`AppStorage`. Keys: `calibration`, `logs`, `milestones`, `foods`, `fasted`, `meals`. **In-place OTA
updates preserve this file**; only uninstall/clear-data wipes it. Storage changes must be additive +
migration-safe — never wipe user data. (Note: the storage path is derived from `Directory.systemTemp`'s
parent `/files/` dir — hacky but stable across updates. Don't change package name or this path without
a migration.)

Key models:
- `DailyLog { date, weight, bf, calories }` — a weigh-in. `lbm = weight*(1-bf)`, `fatMass = weight*bf`.
- `UserCalibration { startWeight, startBf, targetBf, activityMult, deficit, +nullable macro target overrides }`.
- `FoodEntry { id, date, time, name, serving, calories, protein, fat, carbs, nutrients{}, source, barcode }`.
- `Meal { id, name, ingredients[], createdAtMs }`; `MealIngredient { food: FoodTemplate, rawGrams, yieldFactor }`.

### TDEE math (`MathEngine`)
- **Adaptive** (energy balance): once there are 14 days of KNOWN intake, `TDEE ≈ (Σcalories +
  3500·fatLost) / 14`. "Known intake" = days with food logged, OR explicitly marked fasted (0 cal),
  OR a manual calorie entry. Days you simply didn't log are excluded (this is the fasting-vs-didn't-log fix).
- **Baseline** (before 14 days): `BMR(rolling-7-day lean mass) × activityMult` — smoothed so a single
  noisy weigh-in barely moves it.
- A day's calories for the math come from that date's **food-log total** when present (`FoodMath.caloriesByDate`).

### Macro targets (`MacroTargets.compute`)
Auto-derived, editable in Settings: protein ≈ 1 g/lb lean mass, fat ≈ 0.3 g/lb body weight,
carbs = remaining calories, fiber ≈ 14 g/1000 kcal. Drives the Food-tab budget bars.

### Food journal & Cook calculator
- **Food tab:** day view with budget bars (cal + P/F/C/fiber vs targets), an **hourly grid**
  (tap an hour to add at that time), entries grouped under their hour. Add via scan / search / manual.
  Scan + search hit `FoodLookup` (USDA primary, OFF fallback). Confirm sheet has **linked
  Grams↔Servings** fields. Edit/move/copy by **date + time**.
- **Cook tab:** a calculator (NOT a saved library — user disliked clutter). Enter raw ingredients →
  it estimates cooked weight via **per-ingredient yields** (`cookingYield()` keyword table; editable
  per ingredient) → you enter target calories (or cooked grams) → it tells you **how many cooked grams
  to weigh on your plate** + per-ingredient breakdown, and logs it. Calories/macros always come from
  the RAW amounts (cooking only changes water weight). Cooked dishes persist **24h** as "leftovers"
  (`Meal.createdAtMs` / `isActive`) then auto-retire.

### Gotchas (each cost a release to find)
1. **`ota_update`** needs a FileProvider declared in `AndroidManifest.xml` (`OtaUpdateFileProvider`,
   authority `${applicationId}.ota_update_provider`) + `res/xml/filepaths.xml` + `REQUEST_INSTALL_PACKAGES`
   + core-library-desugaring. Without it the app crashes the instant a download finishes.
2. **`mobile_scanner` 7.x** needs **minSdk 23 / compileSdk 36** (pinned to 24/36 in `build.gradle.kts`);
   you MUST own the controller lifecycle (create + `start()` in initState + `dispose()`) or it crashes
   with an ML Kit null-reference; needs `CAMERA` permission; keep ML Kit from R8 via `proguard-rules.pro`
   + `isMinifyEnabled = false`. Bundled ML Kit model adds ~17 MB to the APK.
3. **Bottom sheets**: pad bottom by `viewInsets.bottom + viewPadding.bottom` or content hides behind
   the gesture nav bar.
4. **A broken updater can't fix itself** — escaping a bad shipped version needs ONE manual APK install;
   after that in-app OTA works.
5. Set base64 secrets from **Git Bash**, not PowerShell (see §3).

---

## 5. Remaining roadmap (DETAILED)

The user has a big vision. Build each as its own batch (branch → build → one release). Confirm the
open decisions with the user before building each.

### Batch 3 — Food Advisor  (coaching/insights)
**Goal:** tell the user how they're doing and tie it to results.
- **Tier 1 — heuristics (build first):** compare each day/week's intake to `MacroTargets` and surface
  plain-language flags: "fiber low (12 g vs 30 g goal)", "protein under target 4 of last 7 days",
  "carbs trending high". Compare **predicted deficit vs actual weight change** (we have both: TDEE−deficit
  target and real weight trend) — e.g. "you ate at a 500 deficit but the scale didn't move; either
  intake is underlogged or TDEE is lower than estimated." All as **pure functions over `foods` + `logs` +
  `fasted` + targets** so they're unit-testable.
- **Tier 2 — pattern detection:** lightweight correlation over the log. E.g. average weight change on
  days containing food X vs not; weeks with/without a habit (oatmeal, popsicles, alcohol). Frame as
  **correlation, not proof**; require a minimum sample size before showing anything.
- **OPEN DECISION (ask user):** heuristics-only, or also an **LLM-powered natural-language coach**?
  An LLM (e.g. Claude API) gives smarter phrasing/insights but needs an API key (cost; the key would
  ship in the APK via dart-define like the USDA key, or go through a proxy). Recommend heuristics-first,
  LLM as an optional later layer.
- **Placement:** a card/section on the Dashboard, or a new "Coach" area. Read-only over existing data.
- **Depends on:** accurate calorie data — already in place (food totals + fasting fix feed TDEE).

### Batch 4 — 5K Trainer  (running program)
**Context:** the user is injured (no lifting), running now, very out of shape. Wants a couch-to-5K
that's aware of weight loss + fueling.
- **Plan:** a progressive run/walk program → 5K (C25K-style, ~9 weeks, adjustable for "can barely run").
  Store the plan + completed/skipped workouts.
- **Run logging:** new data type (storage key e.g. `runs`): date, distance, duration, pace; computed.
- **Integration:** show fueling/recovery notes tied to the current deficit; caution that a steep deficit
  + new running can stall recovery (injury). **⚠️ Decide:** do run calories feed TDEE? The adaptive TDEE
  already infers expenditure from weight change, so adding explicit exercise calories risks
  **double-counting** — probably DON'T add them to the adaptive path; treat runs as performance tracking
  + qualitative fueling advice.
- **OPEN DECISIONS (ask user):** how to capture runs — manual entry (simplest, recommended first),
  in-app GPS tracking (needs location permission + a tracking package), or Health Connect import? How
  aggressive should the plan be given the injury?
- **Placement:** likely its own bottom-nav tab ("Run").

### Batch 5 — Sleep import  (hardest / needs discovery)
**Constraint:** the user charges watch + phone on a dock while sleeping (so wrist/phone sleep tracking
won't work) and sleeps with a partner (bed sensors unreliable). So automatic capture may be impossible.
- **Realistic options:** (a) **manual entry** (bed/wake time) as the reliable fallback; (b) **Android
  Health Connect** via the `health` package IF some device already records the user's sleep and syncs
  there.
- **OPEN DECISION (ask user FIRST):** what watch/phone do they have, and does anything currently record
  their sleep at all? That determines whether import is even possible vs manual-only. Don't build before
  answering this.
- **Implementation:** new storage key `sleep`; manual-entry UI; optional Health Connect read of sleep
  sessions (needs the Health Connect permission flow on Android).

### Deferred polish (not yet scheduled)
- **Full MacroFactor aesthetic:** macro **rings** instead of bars; richer visuals on the hourly timeline.
  (Current: bars + a functional hour grid.)
- **Yield-table tuning:** `cookingYield()` defaults are approximate. Gather real cooked-weight data from
  the user and refine; consider deriving yields from USDA raw/cooked entry pairs.
- **More micronutrients:** the USDA `/food/{id}` detail endpoint has more nutrients than search results;
  could fetch on demand.

---

## 6. Decisions log (why things are the way they are)
- **OTA = full-APK self-update** (not Shorebird) — matches the user's Spec Book pattern, needs no local
  Android SDK, handles native changes.
- **USDA primary, Open Food Facts fallback** — USDA is authoritative for whole foods (onion, etc.);
  OFF has better barcode coverage.
- **Cooked weight via per-ingredient yields, calories from raw** — the user CANNOT weigh the whole pot,
  only the portion on the plate; so the app estimates cooked weight to output a weighable gram number.
- **Meals = calculator + 24h leftovers, NOT a permanent library** — the user disliked the saved-meal
  clutter; each cook is fresh; leftovers auto-expire.
- **Macro targets auto-derived + editable.**
- **Fasting flag** distinguishes a real fast (counts as 0 cal in TDEE) from a day not logged (excluded).
- **Large batches, feature branches, one release per batch.**

## 7. How to verify before shipping
```
flutter analyze lib test      # must be clean (deprecation infos are OK)
flutter test                  # all tests must pass
```
Then ship (§3) and have the user update on-device for anything UI/camera/install-related.
