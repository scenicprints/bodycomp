import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

import 'campaign.dart';
import 'creatures.dart';

// ═══════════════════════════════════════════════════════════════════════
// HOME-SCREEN WIDGET — today's fight on the launcher.
//
// The whole widget face is rendered here as one PNG (portrait, name, HP
// bar with the live pending slice, today's swing) and handed to a dumb
// native ImageView — full control of the look, zero RemoteViews layout
// fights. Updated every time the app saves anything that moves a number.
// ═══════════════════════════════════════════════════════════════════════

class CampaignWidget {
  static const int _w = 840;
  static const int _h = 320;
  static bool _busy = false;

  static Future<void> push(CampaignState c, Color accent) async {
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      _draw(canvas, c, accent);
      final ui.Image img =
          await recorder.endRecording().toImage(_w, _h);
      final ByteData? bytes =
          await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        return;
      }
      final String dir = '${Directory.systemTemp.parent.path}/files';
      final File f = File('$dir/campaign_widget.png');
      await f.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      await HomeWidget.saveWidgetData<String>('cw_image', f.path);
      await HomeWidget.updateWidget(
          name: 'CampaignWidgetProvider',
          qualifiedAndroidName:
              'com.scenicprints.bodycomp.CampaignWidgetProvider');
    } catch (_) {
      // The widget is a luxury — never let it break a save.
    } finally {
      _busy = false;
    }
  }

  static void _draw(Canvas canvas, CampaignState c, Color accent) {
    const Color bg = Color(0xFF191919);
    const Color border = Color(0xFF2C2C2C);
    final RRect frame = RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 840, 320), const Radius.circular(44));
    canvas.drawRRect(frame, Paint()..color = bg);
    canvas.drawRRect(
        frame,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);

    final bool boss = c.activeBoss != null;
    // Portrait on the left.
    canvas.save();
    canvas.translate(28, 30);
    final CreatureSpec spec = boss
        ? CreatureSpec.forBoss(kWeekendBosses
            .indexWhere((BossDef d) => d.name == c.activeBoss!.boss.name)
            .clamp(0, kWeekendBosses.length - 1))
        : CreatureSpec.forEnemy(c.enemy);
    final double frac = boss || c.enemyMaxHp <= 0
        ? 1.0
        : (c.enemyHp / c.enemyMaxHp).clamp(0.0, 1.0);
    CreaturePainter(spec, damage: boss ? 0 : 1 - frac)
        .paint(canvas, const Size(260, 260));
    canvas.restore();

    void text(String s, double x, double y,
        {double size = 34,
        Color color = const Color(0xFFEEEEEE),
        FontWeight weight = FontWeight.w800,
        double spacing = 0}) {
      final TextPainter tp = TextPainter(
          text: TextSpan(
              text: s,
              style: TextStyle(
                  fontSize: size,
                  color: color,
                  fontWeight: weight,
                  letterSpacing: spacing)),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…')
        ..layout(maxWidth: 520);
      tp.paint(canvas, Offset(x, y));
    }

    final String title =
        boss ? c.activeBoss!.boss.name : c.enemy.name;
    final String over = boss
        ? 'WEEKEND BOSS'
        : c.enemy.zoneName.toUpperCase();
    text(over, 300, 42,
        size: 20, color: const Color(0xFF888888), spacing: 3);
    text(title, 300, 70, size: 44);

    if (boss) {
      final BossRecord b = c.activeBoss!;
      if (b.result == 'no_mark') {
        text('No mark — weigh in to start the fight', 300, 150,
            size: 26, color: const Color(0xFFD98A94), weight: FontWeight.w600);
      } else {
        text(
            'Beat him: gain < +${b.threshold.toStringAsFixed(1)} lb',
            300,
            140,
            size: 28,
            color: const Color(0xFFE0A9B4),
            weight: FontWeight.w700);
        text('Verdict Monday morning — weigh in.', 300, 182,
            size: 24, color: const Color(0xFF999999), weight: FontWeight.w600);
      }
      return;
    }

    // HP bar with the live pending slice.
    final double pending =
        !c.weekendMode && (c.pendingDamage ?? 0) > 0 ? c.pendingDamage! : 0;
    const Rect bar = Rect.fromLTWH(300, 140, 480, 30);
    final RRect barR =
        RRect.fromRectAndRadius(bar, const Radius.circular(10));
    canvas.drawRRect(barR, Paint()..color = const Color(0xFF241417));
    canvas.save();
    canvas.clipRRect(barR);
    final double ghostFrac = frac;
    final double solidFrac =
        c.enemyMaxHp <= 0 ? 0 : ((c.enemyHp - pending) / c.enemyMaxHp).clamp(0.0, 1.0);
    canvas.drawRect(
        Rect.fromLTWH(bar.left, bar.top, bar.width * solidFrac, bar.height),
        Paint()..color = const Color(0xFFCE4257));
    if (ghostFrac > solidFrac) {
      final Rect ghost = Rect.fromLTWH(bar.left + bar.width * solidFrac,
          bar.top, bar.width * (ghostFrac - solidFrac), bar.height);
      canvas.drawRect(ghost,
          Paint()..color = const Color(0xFFCE4257).withValues(alpha: 0.3));
      final Paint stripe = Paint()
        ..color = const Color(0xFFE88A98).withValues(alpha: 0.55)
        ..strokeWidth = 3;
      canvas.save();
      canvas.clipRect(ghost);
      for (double x = ghost.left - 40; x < ghost.right + 40; x += 16) {
        canvas.drawLine(Offset(x, bar.bottom + 4),
            Offset(x + bar.height + 8, bar.top - 4), stripe);
      }
      canvas.restore();
    }
    canvas.restore();

    String num(double v) {
      final String s = v.round().toString();
      final StringBuffer b = StringBuffer();
      for (int i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
        b.write(s[i]);
      }
      return b.toString();
    }

    text('${num(c.enemyHp)} / ${num(c.enemyMaxHp)} HP', 300, 184,
        size: 24, color: const Color(0xFF999999), weight: FontWeight.w700);

    String swing;
    Color swingColor;
    if (c.weekendMode) {
      swing = 'Weekend — the boss is the fight';
      swingColor = const Color(0xFF888888);
    } else if (pending > 0 && pending >= c.enemyHp && c.enemyHp > 0) {
      swing = 'LETHAL — today finishes it';
      swingColor = const Color(0xFFF0C040);
    } else if (pending > 0) {
      swing = 'Today: −${num(pending)} pending';
      swingColor = accent;
    } else if ((c.pendingDamage ?? 1) < 0) {
      swing = 'Over maintenance — he\'s healing';
      swingColor = const Color(0xFFCE4257);
    } else {
      swing = 'Nothing logged — log to swing';
      swingColor = const Color(0xFF999999);
    }
    text(swing, 300, 232, size: 30, color: swingColor,
        weight: FontWeight.w700);

    // Player HP chip, bottom right corner.
    final double php = max(0, c.playerHp);
    text('YOU ${php.round()}/${c.playerMaxHp.round()}', 640, 42,
        size: 22,
        color: php / max(c.playerMaxHp, 1) < 0.35
            ? const Color(0xFFCE4257)
            : const Color(0xFF3CD6A3),
        weight: FontWeight.w800);
  }
}
