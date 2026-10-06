import 'package:flutter/material.dart';

import '../map/map_painter.dart';
import 'live_location_client.dart';

/// Plots live people on the map: initials for employees, a wheelchair badge for people
/// who need assistance, and a shield badge for emergency responders.
class PeoplePainter extends CustomPainter {
  PeoplePainter({
    required this.users,
    required this.projection,
    required this.now,
  });

  static const _staleAfter = Duration(seconds: 30);
  static const _palette = [
    Color(0xFF1A73E8),
    Color(0xFFE37400),
    Color(0xFF188038),
    Color(0xFFD93025),
    Color(0xFF00897B),
  ];

  final List<LiveUser> users;
  final MapProjection projection;
  final DateTime now;

  @override
  void paint(Canvas canvas, Size size) {
    // Responders last so they stay visible over the people they are helping.
    final ordered = [
      ...users.where((u) => !u.isResponder),
      ...users.where((u) => u.isResponder),
    ];
    for (final user in ordered) {
      final stale = now.difference(user.seenAt) > _staleAfter;
      final badge = user.isResponder || user.hasDisability;
      final base = user.isResponder
          ? GColors.responder
          : user.hasDisability
          ? GColors.assist
          : _palette[user.userId.hashCode.abs() % _palette.length];
      final color = stale ? base.withValues(alpha: 0.45) : base;
      final c = projection.toPixels(user.position);

      if (badge) {
        canvas.drawCircle(
          c,
          21,
          Paint()..color = base.withValues(alpha: stale ? 0.12 : 0.22),
        );
      }
      canvas.drawCircle(
        c + const Offset(0, 1.5),
        15,
        Paint()..color = const Color(0x33000000),
      );
      canvas.drawCircle(c, 15, Paint()..color = Colors.white);
      canvas.drawCircle(c, 12, Paint()..color = color);
      if (user.isResponder) {
        _icon(canvas, Icons.health_and_safety_rounded, c, 17);
      } else if (user.hasDisability) {
        _icon(canvas, Icons.accessible_rounded, c, 17);
      } else {
        _text(
          canvas,
          user.name.isEmpty ? '?' : user.name.characters.first.toUpperCase(),
          c,
          const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        );
      }

      final label = _layout(
        user.name,
        TextStyle(
          color: stale ? GColors.textMuted : GColors.text,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      );
      final labelDy = badge ? 21 : 15;
      final pill = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: c + Offset(0, labelDy + 4 + label.height / 2 + 2),
          width: label.width + 12,
          height: label.height + 4,
        ),
        const Radius.circular(10),
      );
      canvas.drawRRect(pill, Paint()..color = const Color(0xE6FFFFFF));
      label.paint(
        canvas,
        pill.center - Offset(label.width / 2, label.height / 2),
      );
    }
  }

  TextPainter _layout(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: 140);

  void _text(Canvas canvas, String text, Offset centre, TextStyle style) {
    final tp = _layout(text, style);
    tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
  }

  void _icon(Canvas canvas, IconData icon, Offset centre, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(PeoplePainter old) => true;
}
