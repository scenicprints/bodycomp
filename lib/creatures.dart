import 'dart:math';

import 'package:flutter/material.dart';

import 'campaign.dart';

// ═══════════════════════════════════════════════════════════════════════
// CREATURES — one parameterized painter, a hundred-plus distinct monsters.
//
// Every enemy's look is deterministically seeded by its road index: body
// shape, eyes, horns, teeth, limbs, palette jitter, accessory. Signature
// enemies and the weekend bosses get hand-tuned overrides on top. Deeper
// laps of the road grow more horns and eyes and go darker — for free.
// No wings. Nothing here flies away from its problems.
// ═══════════════════════════════════════════════════════════════════════

class ZonePalette {
  final Color base;
  final Color belly;
  const ZonePalette(this.base, this.belly);
}

const List<ZonePalette> kZonePalettes = <ZonePalette>[
  ZonePalette(Color(0xFF3CB88F), Color(0xFF9FE5C8)), // Pantry Shallows
  ZonePalette(Color(0xFFB0913C), Color(0xFFE2CE8F)), // Snackfang Woods
  ZonePalette(Color(0xFFD98F41), Color(0xFFF2CFA0)), // Graze Plains
  ZonePalette(Color(0xFF7A5CD6), Color(0xFFC3B2F0)), // Midnight Kitchen
  ZonePalette(Color(0xFFD6603C), Color(0xFFF0B49E)), // Buffet Barrens
  ZonePalette(Color(0xFF6C8FB0), Color(0xFFBBD2E4)), // Plateau Peaks
];

/// Accessories only the signature enemies carry.
const int kAccNone = 0;
const int kAccGlass = 1; // The Nightcap
const int kAccSpoons = 2; // Second Helping
const int kAccCrown = 3; // Sir Seconds / bosses
const int kAccPlate = 4; // Plate Cleaner / The All-You-Can-Eat

class CreatureSpec {
  final int shape; // 0 blob · 1 round · 2 tall · 3 wide · 4 spiky
  final int eyes; // 1..5
  final int horns; // 0..4
  final int teeth; // 0 smile · 1 flat · 2 fangs · 3 zigzag
  final bool arms;
  final bool legs;
  final bool ghost; // translucent, wavy hem, no legs
  final bool wall; // The Plateau: a wall with a face
  final bool droopy; // half-lidded eyes
  final bool angry; // slanted brows
  final int accessory;
  final double bulk; // 0.85..1.35 visual mass
  final Color base;
  final Color belly;
  final bool guardian;

  const CreatureSpec({
    required this.shape,
    required this.eyes,
    required this.horns,
    required this.teeth,
    required this.arms,
    required this.legs,
    required this.ghost,
    required this.wall,
    required this.droopy,
    required this.angry,
    required this.accessory,
    required this.bulk,
    required this.base,
    required this.belly,
    required this.guardian,
  });

  /// The one look every enemy at [index] will always have.
  factory CreatureSpec.forEnemy(EnemyDef e) {
    final Random rng = Random(e.index * 7919 + 31);
    final ZonePalette pal = kZonePalettes[e.zone];
    // Slight per-creature palette jitter so zone-mates aren't clones.
    final double jitter = (rng.nextDouble() - 0.5) * 0.3;
    final Color base = jitter >= 0
        ? Color.lerp(pal.base, Colors.white, jitter)!
        : Color.lerp(pal.base, Colors.black, -jitter)!;
    // Deeper laps go darker and grow more of everything.
    final Color deepBase = e.depth == 0
        ? base
        : Color.lerp(base, const Color(0xFF1A0F2A), min(0.25 * e.depth, 0.6))!;

    int shape = rng.nextInt(5);
    int eyes = 1 + rng.nextInt(3) + min(e.depth, 2);
    int horns = rng.nextInt(3) + min(e.depth, 2);
    int teeth = rng.nextInt(4);
    bool arms = rng.nextBool();
    bool legs = shape != 0 || rng.nextBool();
    bool ghost = false;
    bool wall = false;
    bool droopy = false;
    bool angry = e.guardian;
    int accessory = kAccNone;

    // Hand-tuned signatures (positions on the first lap; deeper laps of the
    // same slot keep the identity).
    switch (e.index % 60) {
      case 4: // Second Helping — round, contented, two spoons
        shape = 1;
        accessory = kAccSpoons;
        teeth = 0;
        angry = false;
        break;
      case 9: // The Fridge Goblin — hates being seen
        shape = 2;
        eyes = max(eyes, 2);
        angry = true;
        break;
      case 18: // Portion Ghost — translucent for a reason
        ghost = true;
        legs = false;
        horns = 0;
        teeth = 0;
        break;
      case 28: // Plate Cleaner
        accessory = kAccPlate;
        break;
      case 29: // Sir Seconds — a knight sworn to the second serving
        accessory = kAccCrown;
        shape = 2;
        break;
      case 30: // The Nightcap — droopy-eyed, holding a glass, patient
        droopy = true;
        eyes = 2;
        accessory = kAccGlass;
        arms = true;
        angry = false;
        break;
      case 49: // The All-You-Can-Eat
        accessory = kAccPlate;
        shape = 3;
        break;
      case 50: // The Stall — barely a face at all
        droopy = true;
        horns = 0;
        teeth = 0;
        break;
      case 59: // The Plateau — a wall with a face
        wall = true;
        ghost = false;
        legs = false;
        arms = false;
        horns = 0;
        eyes = 2;
        droopy = true;
        teeth = 1;
        break;
    }

    return CreatureSpec(
      shape: shape,
      eyes: eyes.clamp(1, 5),
      horns: horns.clamp(0, 4),
      teeth: teeth,
      arms: arms,
      legs: legs && !ghost && !wall,
      ghost: ghost,
      wall: wall,
      droopy: droopy,
      angry: angry,
      accessory: accessory,
      bulk: (0.85 + 0.5 * ((e.sizeMult - 0.75) / 2.75)).clamp(0.85, 1.35),
      base: deepBase,
      belly: Color.lerp(pal.belly, deepBase, e.depth == 0 ? 0.0 : 0.35)!,
      guardian: e.guardian,
    );
  }

  /// Weekend bosses: big, dark, crowned, individually seeded.
  factory CreatureSpec.forBoss(int rosterIndex) {
    final Random rng = Random(rosterIndex * 104729 + 7);
    return CreatureSpec(
      shape: <int>[1, 3, 4][rng.nextInt(3)],
      eyes: 2 + rng.nextInt(2),
      horns: 2 + rng.nextInt(3),
      teeth: 2 + rng.nextInt(2),
      arms: true,
      legs: true,
      ghost: false,
      wall: false,
      droopy: false,
      angry: true,
      accessory: kAccCrown,
      bulk: 1.35,
      base: Color.lerp(const Color(0xFF9E3B4E),
          const Color(0xFF5A2D6E), rng.nextDouble())!,
      belly: const Color(0xFFE0A9B4),
      guardian: true,
    );
  }
}

class CreaturePainter extends CustomPainter {
  final CreatureSpec spec;
  /// 0..1 — how hurt it is. Hurt creatures dim and their eyes shrink.
  final double damage;
  const CreaturePainter(this.spec, {this.damage = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide / 100.0;
    canvas.save();
    canvas.translate((size.width - 100 * s) / 2, (size.height - 100 * s) / 2);
    canvas.scale(s);

    final double hurt = damage.clamp(0.0, 1.0);
    final double alpha = spec.ghost ? 0.72 : 1.0;
    final Color body =
        Color.lerp(spec.base, const Color(0xFF2A2A2A), hurt * 0.35)!
            .withValues(alpha: alpha);
    final Color outline =
        Color.lerp(spec.base, Colors.black, 0.55)!.withValues(alpha: alpha);
    final Paint fill = Paint()..color = body;
    final Paint line = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;

    // Ground shadow.
    canvas.drawOval(
        Rect.fromCenter(
            center: const Offset(50, 91),
            width: 56 * spec.bulk,
            height: 9),
        Paint()..color = Colors.black.withValues(alpha: 0.35));

    final double b = spec.bulk;
    final Path bodyPath = _bodyPath(b);

    // Legs first so the body overlaps them.
    if (spec.legs) {
      final Paint leg = Paint()..color = outline;
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: Offset(50 - 12 * b, 84), width: 9, height: 12),
              const Radius.circular(4)),
          leg);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: Offset(50 + 12 * b, 84), width: 9, height: 12),
              const Radius.circular(4)),
          leg);
    }

    // Horns behind the body.
    for (int i = 0; i < spec.horns; i++) {
      final double t = spec.horns == 1 ? 0.5 : i / (spec.horns - 1);
      final double hx = 50 + (t - 0.5) * 34 * b;
      final double topY = spec.wall ? 34 : 28;
      final Path horn = Path()
        ..moveTo(hx - 4, topY + 6)
        ..lineTo(hx + (t - 0.5) * 10, topY - 8 - 3 * spec.bulk)
        ..lineTo(hx + 4, topY + 6)
        ..close();
      canvas.drawPath(horn, Paint()..color = outline);
    }

    canvas.drawPath(bodyPath, fill);
    canvas.drawPath(bodyPath, line);

    if (spec.wall) {
      // Brick seams.
      final Paint seam = Paint()
        ..color = outline.withValues(alpha: 0.7)
        ..strokeWidth = 1.6;
      for (final double y in <double>[46, 60, 74]) {
        canvas.drawLine(Offset(22, y), Offset(78, y), seam);
      }
      canvas.drawLine(const Offset(38, 34), const Offset(38, 46), seam);
      canvas.drawLine(const Offset(62, 46), const Offset(62, 60), seam);
      canvas.drawLine(const Offset(44, 60), const Offset(44, 74), seam);
    } else if (!spec.ghost) {
      // Belly patch.
      canvas.drawOval(
          Rect.fromCenter(
              center: Offset(50, 66 - (spec.shape == 3 ? 4 : 0)),
              width: 26 * b,
              height: 20 * b),
          Paint()..color = spec.belly.withValues(alpha: 0.55));
    }

    // Arms.
    if (spec.arms) {
      canvas.drawLine(Offset(50 - 26 * b, 58), Offset(50 - 34 * b, 66), line);
      canvas.drawLine(Offset(50 + 26 * b, 58), Offset(50 + 34 * b, 66), line);
    }

    _face(canvas, hurt, outline);
    _accessory(canvas, outline, b);
    canvas.restore();
  }

  Path _bodyPath(double b) {
    switch (spec.shape) {
      case 1: // round
        return Path()
          ..addOval(Rect.fromCenter(
              center: const Offset(50, 58),
              width: 56 * b,
              height: 54 * b));
      case 2: // tall
        return Path()
          ..addRRect(RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: const Offset(50, 56), width: 42 * b, height: 60 * b),
              Radius.circular(20 * b)));
      case 3: // wide
        return Path()
          ..addOval(Rect.fromCenter(
              center: const Offset(50, 62),
              width: 66 * b,
              height: 46 * b));
      case 4: // spiky
        final Path p = Path();
        const int points = 11;
        for (int i = 0; i <= points * 2; i++) {
          final double ang = pi * i / points - pi / 2;
          final double r = (i.isEven ? 30 : 24) * b;
          final double x = 50 + r * cos(ang);
          final double y = 58 + r * sin(ang) * 0.92;
          if (i == 0) {
            p.moveTo(x, y);
          } else {
            p.lineTo(x, y);
          }
        }
        p.close();
        return p;
      default:
        if (spec.wall) {
          return Path()
            ..addRRect(RRect.fromRectAndRadius(
                Rect.fromCenter(
                    center: const Offset(50, 60), width: 60, height: 54),
                const Radius.circular(6)));
        }
        if (spec.ghost) {
          final Path p = Path()
            ..moveTo(50 - 26 * b, 62)
            ..arcToPoint(Offset(50 + 26 * b, 62),
                radius: Radius.circular(27 * b));
          // Wavy hem.
          for (int i = 0; i < 4; i++) {
            final double x0 = 50 + 26 * b - (i + 0.5) * 13 * b;
            p.quadraticBezierTo(
                x0 + 3 * b, i.isEven ? 84 : 74, x0 - 6.5 * b, 78);
          }
          p.close();
          return p;
        }
        // blob — lumpy oval
        return Path()
          ..moveTo(24 * (2 - spec.bulk), 60)
          ..cubicTo(20, 30, 44, 26, 52, 30)
          ..cubicTo(66, 26, 82, 38, 78, 58)
          ..cubicTo(82, 78, 62, 86, 48, 84)
          ..cubicTo(32, 86, 20, 76, 24 * (2 - spec.bulk), 60)
          ..close();
    }
  }

  void _face(Canvas canvas, double hurt, Color outline) {
    final double eyeY = spec.wall ? 42 : 48;
    final double eyeR = (5.5 - hurt * 1.5) * (spec.bulk * 0.9);
    final int n = spec.eyes;
    for (int i = 0; i < n; i++) {
      final double t = n == 1 ? 0.5 : i / (n - 1);
      final double ex = 50 + (t - 0.5) * (n > 3 ? 30 : 22) * spec.bulk;
      final double ey = eyeY - sin(t * pi) * 3;
      canvas.drawCircle(
          Offset(ex, ey), eyeR, Paint()..color = const Color(0xFFF4F1E8));
      canvas.drawCircle(Offset(ex + 0.8, ey + (spec.droopy ? 1.6 : 0.4)),
          eyeR * 0.45, Paint()..color = const Color(0xFF17141A));
      if (spec.droopy) {
        // Half-lid.
        canvas.drawArc(
            Rect.fromCircle(center: Offset(ex, ey), radius: eyeR + 0.5),
            pi,
            pi,
            false,
            Paint()
              ..color = outline
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3);
      } else if (spec.angry) {
        final double dir = ex < 50 ? 1 : -1;
        canvas.drawLine(
            Offset(ex - eyeR * dir, ey - eyeR - 1.5),
            Offset(ex + eyeR * dir, ey - eyeR + 2.5),
            Paint()
              ..color = outline
              ..strokeWidth = 2.6
              ..strokeCap = StrokeCap.round);
      }
    }

    // Mouth.
    final double my = spec.wall ? 52 : 64;
    final Paint mp = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    switch (spec.teeth) {
      case 1: // flat open mouth
        final Rect r = Rect.fromCenter(
            center: Offset(50, my), width: 20 * spec.bulk, height: 8);
        canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)),
            Paint()..color = const Color(0xFF17141A));
        canvas.drawLine(Offset(r.left + 5, r.top), Offset(r.left + 5, r.bottom),
            Paint()
              ..color = const Color(0xFFF4F1E8)
              ..strokeWidth = 3);
        canvas.drawLine(
            Offset(r.right - 5, r.top),
            Offset(r.right - 5, r.bottom),
            Paint()
              ..color = const Color(0xFFF4F1E8)
              ..strokeWidth = 3);
        break;
      case 2: // fangs
        final Path m = Path()
          ..moveTo(50 - 10 * spec.bulk, my - 2)
          ..quadraticBezierTo(50, my + 4, 50 + 10 * spec.bulk, my - 2);
        canvas.drawPath(m, mp);
        for (final double fx in <double>[50 - 6 * spec.bulk, 50 + 6 * spec.bulk]) {
          final Path fang = Path()
            ..moveTo(fx - 2.4, my)
            ..lineTo(fx, my + 6)
            ..lineTo(fx + 2.4, my)
            ..close();
          canvas.drawPath(fang, Paint()..color = const Color(0xFFF4F1E8));
        }
        break;
      case 3: // zigzag
        final Path z = Path()..moveTo(50 - 12 * spec.bulk, my);
        for (int i = 0; i < 5; i++) {
          z.lineTo(50 - 12 * spec.bulk + (i + 0.5) * 4.8 * spec.bulk,
              my + (i.isEven ? 4.5 : -1.5));
        }
        z.lineTo(50 + 12 * spec.bulk, my);
        canvas.drawPath(z, mp);
        break;
      default: // a little smile (or a hurt grimace)
        final Path m = Path()
          ..moveTo(50 - 8 * spec.bulk, my)
          ..quadraticBezierTo(
              50, my + (hurt > 0.6 ? -4 : 5), 50 + 8 * spec.bulk, my);
        canvas.drawPath(m, mp);
    }
  }

  void _accessory(Canvas canvas, Color outline, double b) {
    switch (spec.accessory) {
      case kAccGlass:
        final Rect g = Rect.fromLTWH(50 + 30 * b, 58, 9, 11);
        canvas.drawRRect(
            RRect.fromRectAndRadius(g, const Radius.circular(2)),
            Paint()..color = const Color(0xFFB9853F));
        canvas.drawRect(Rect.fromLTWH(g.left, g.top, g.width, 3),
            Paint()..color = const Color(0xFFF4F1E8).withValues(alpha: 0.6));
        break;
      case kAccSpoons:
        final Paint sp = Paint()
          ..color = const Color(0xFFC9CDD4)
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(Offset(50 - 34 * b, 66), Offset(50 - 40 * b, 52), sp);
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(50 - 41 * b, 49), width: 7, height: 9),
            Paint()..color = const Color(0xFFC9CDD4));
        canvas.drawLine(Offset(50 + 34 * b, 66), Offset(50 + 40 * b, 52), sp);
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(50 + 41 * b, 49), width: 7, height: 9),
            Paint()..color = const Color(0xFFC9CDD4));
        break;
      case kAccCrown:
        final double cy = spec.wall ? 30 : 26;
        final Path crown = Path()
          ..moveTo(40, cy)
          ..lineTo(42, cy - 8)
          ..lineTo(46.5, cy - 2)
          ..lineTo(50, cy - 10)
          ..lineTo(53.5, cy - 2)
          ..lineTo(58, cy - 8)
          ..lineTo(60, cy)
          ..close();
        canvas.drawPath(crown, Paint()..color = const Color(0xFFF0C040));
        break;
      case kAccPlate:
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(50, 88), width: 34 * b, height: 7),
            Paint()..color = const Color(0xFFE8E4D8));
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(50, 88), width: 20 * b, height: 4),
            Paint()..color = const Color(0xFFC9C4B4));
        break;
    }
  }

  @override
  bool shouldRepaint(CreaturePainter old) =>
      old.spec != spec || old.damage != damage;
}

// ═══════════════════════════════════════════════════════════════════════
// CHAD — smug, metronomic, reacts to the gap.
// mood: 0 relaxed (way ahead) · 1 smug · 2 sweating (you're close) ·
//       3 annoyed (you passed him)
// ═══════════════════════════════════════════════════════════════════════

class ChadPainter extends CustomPainter {
  final int mood;
  const ChadPainter(this.mood);

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide / 100.0;
    canvas.save();
    canvas.translate((size.width - 100 * s) / 2, (size.height - 100 * s) / 2);
    canvas.scale(s);

    const Color skin = Color(0xFFE3B68C);
    const Color hair = Color(0xFF6B4A2B);
    const Color shirt = Color(0xFF3A6EA5);
    final Paint lineP = Paint()
      ..color = const Color(0xFF2A1E14)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    // Shoulders + popped collar.
    final Path torso = Path()
      ..moveTo(18, 100)
      ..quadraticBezierTo(20, 72, 38, 68)
      ..lineTo(62, 68)
      ..quadraticBezierTo(80, 72, 82, 100)
      ..close();
    canvas.drawPath(torso, Paint()..color = shirt);
    canvas.drawPath(
        Path()
          ..moveTo(38, 68)
          ..lineTo(44, 76)
          ..lineTo(50, 69)
          ..lineTo(56, 76)
          ..lineTo(62, 68),
        Paint()
          ..color = const Color(0xFF2E5884)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);

    // Crossed arms (mood 3 pulls them tighter).
    final double armY = mood == 3 ? 84 : 87;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(50, armY + 5), width: 52, height: 13),
            const Radius.circular(7)),
        Paint()..color = const Color(0xFF335F8E));
    canvas.drawCircle(Offset(30, armY + 5), 5.5, Paint()..color = skin);
    canvas.drawCircle(Offset(70, armY + 5), 5.5, Paint()..color = skin);

    // Head + neck.
    canvas.drawRect(const Rect.fromLTWH(44, 58, 12, 12), Paint()..color = skin);
    canvas.drawOval(const Rect.fromLTWH(29, 18, 42, 46), Paint()..color = skin);

    // The swoop.
    final Path swoop = Path()
      ..moveTo(27, 38)
      ..quadraticBezierTo(26, 16, 50, 14)
      ..quadraticBezierTo(74, 14, 73, 34)
      ..quadraticBezierTo(64, 20, 46, 24)
      ..quadraticBezierTo(32, 27, 30, 42)
      ..close();
    canvas.drawPath(swoop, Paint()..color = hair);

    // Eyes / sunglasses.
    if (mood == 0) {
      final Paint dark = Paint()..color = const Color(0xFF17141A);
      canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(33, 33, 15, 9),
              const Radius.circular(4)),
          dark);
      canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(52, 33, 15, 9),
              const Radius.circular(4)),
          dark);
      canvas.drawLine(const Offset(48, 36), const Offset(52, 36), lineP);
    } else {
      // Half-lidded smugness; worried lift when sweating; knit when annoyed.
      final double lidTilt = mood == 3 ? 3 : 0;
      for (final double ex in <double>[40, 60]) {
        final double dir = ex < 50 ? 1 : -1;
        canvas.drawArc(Rect.fromCircle(center: Offset(ex, 38), radius: 5),
            mood == 2 ? -pi * 0.9 : -pi, pi, false, lineP);
        canvas.drawCircle(Offset(ex + 1, 39),
            2.1, Paint()..color = const Color(0xFF17141A));
        canvas.drawLine(Offset(ex - 5 * dir, 30 + lidTilt * dir),
            Offset(ex + 5 * dir, 28 - lidTilt * dir), lineP);
      }
    }

    // Nose.
    canvas.drawLine(const Offset(50, 40), const Offset(52, 47), lineP);

    // Mouth by mood.
    final Path mouth = Path();
    switch (mood) {
      case 2: // flat, tight
        mouth.moveTo(43, 54);
        mouth.lineTo(57, 54);
        break;
      case 3: // frown
        mouth.moveTo(42, 56);
        mouth.quadraticBezierTo(50, 51, 58, 56);
        break;
      default: // the smirk
        mouth.moveTo(41, 53);
        mouth.quadraticBezierTo(52, 57, 60, 50);
    }
    canvas.drawPath(mouth, lineP);

    // Sweat when you're closing in.
    if (mood == 2) {
      final Paint drop = Paint()..color = const Color(0xFF7FB8E8);
      for (final Offset o in <Offset>[const Offset(72, 26), const Offset(76, 34)]) {
        final Path p = Path()
          ..moveTo(o.dx, o.dy - 4)
          ..quadraticBezierTo(o.dx + 3.4, o.dy + 2, o.dx, o.dy + 3.4)
          ..quadraticBezierTo(o.dx - 3.4, o.dy + 2, o.dx, o.dy - 4);
        canvas.drawPath(p, drop);
      }
    }

    // The relaxed one gets a drink.
    if (mood == 0) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              const Rect.fromLTWH(76, 78, 10, 14), const Radius.circular(2)),
          Paint()..color = const Color(0xFFE05B4B));
      canvas.drawLine(const Offset(81, 78), const Offset(84, 70),
          Paint()
            ..color = const Color(0xFFF4F1E8)
            ..strokeWidth = 2);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ChadPainter old) => old.mood != mood;
}

// ═══════════════════════════════════════════════════════════════════════
// THE HERO — your silhouette, driven by your actual body composition.
// [leanness] 0..1 maps start BF% → target BF%; the figure narrows and
// definition comes in as the real number drops.
// ═══════════════════════════════════════════════════════════════════════

class HeroPainter extends CustomPainter {
  final double leanness; // 0..1
  final int tier; // 0 none · 1 bronze · 2 silver · 3 gold belt
  final Color accent;
  const HeroPainter(this.leanness, this.tier, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide / 100.0;
    canvas.save();
    canvas.translate((size.width - 100 * s) / 2, (size.height - 100 * s) / 2);
    canvas.scale(s);

    final double lean = leanness.clamp(0.0, 1.0);
    const Color skin = Color(0xFFD9A97C);
    const Color kit = Color(0xFF2E3440);
    final Paint lineP = Paint()
      ..color = const Color(0xFF1A1611)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    canvas.drawOval(
        Rect.fromCenter(center: const Offset(50, 93), width: 40, height: 7),
        Paint()..color = Colors.black.withValues(alpha: 0.35));

    // Widths narrow as the real BF% drops.
    final double shoulder = 21 - lean * 1.5;
    final double waist = 17 - lean * 6.5;
    final double hip = 15 - lean * 4;

    // Legs.
    final Paint kitP = Paint()..color = kit;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(50 - hip / 2, 80), width: 8.5, height: 22),
            const Radius.circular(4)),
        kitP);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(50 + hip / 2, 80), width: 8.5, height: 22),
            const Radius.circular(4)),
        kitP);

    // Torso: shoulders → waist taper.
    final Path torso = Path()
      ..moveTo(50 - shoulder, 40)
      ..quadraticBezierTo(50 - shoulder - 2, 52, 50 - waist, 66)
      ..lineTo(50 + waist, 66)
      ..quadraticBezierTo(50 + shoulder + 2, 52, 50 + shoulder, 40)
      ..quadraticBezierTo(50, 35, 50 - shoulder, 40)
      ..close();
    canvas.drawPath(torso, Paint()..color = accent.withValues(alpha: 0.9));

    // Definition line appears as leanness climbs.
    if (lean > 0.45) {
      final Paint def = Paint()
        ..color = Colors.black.withValues(alpha: 0.25 * lean)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      canvas.drawLine(const Offset(50, 46), const Offset(50, 62), def);
      canvas.drawArc(const Rect.fromLTWH(40, 42, 9, 8), 0, pi, false, def);
      canvas.drawArc(const Rect.fromLTWH(51, 42, 9, 8), 0, pi, false, def);
    }

    // Belt by tier.
    if (tier > 0) {
      const List<Color> belts = <Color>[
        Colors.transparent,
        Color(0xFFB0703C),
        Color(0xFFC9CDD4),
        Color(0xFFF0C040),
      ];
      canvas.drawRect(
          Rect.fromCenter(
              center: const Offset(50, 66.5), width: waist * 2 + 2, height: 4),
          Paint()..color = belts[min(tier, 3)]);
    }

    // Arms.
    final double armW = 6.5 - lean * 1.5;
    for (final int dir in <int>[-1, 1]) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: Offset(50 + dir * (shoulder + 3.5), 52),
                  width: armW,
                  height: 24),
              const Radius.circular(3.5)),
          Paint()..color = skin);
    }

    // Head.
    canvas.drawRect(const Rect.fromLTWH(46.5, 34, 7, 6), Paint()..color = skin);
    canvas.drawOval(const Rect.fromLTWH(40, 14, 20, 22), Paint()..color = skin);
    canvas.drawPath(
        Path()
          ..moveTo(40, 24)
          ..quadraticBezierTo(40, 13, 50, 13)
          ..quadraticBezierTo(60, 13, 60, 24)
          ..quadraticBezierTo(56, 17, 48, 18)
          ..quadraticBezierTo(42, 19, 40, 24)
          ..close(),
        Paint()..color = const Color(0xFF3A2E22));
    canvas.drawCircle(const Offset(46, 25), 1.4,
        Paint()..color = const Color(0xFF17141A));
    canvas.drawCircle(const Offset(54, 25), 1.4,
        Paint()..color = const Color(0xFF17141A));
    canvas.drawPath(
        Path()
          ..moveTo(46, 30)
          ..quadraticBezierTo(50, 32.5, 54, 30),
        lineP);
    canvas.restore();
  }

  @override
  bool shouldRepaint(HeroPainter old) =>
      old.leanness != leanness || old.tier != tier || old.accent != accent;
}
