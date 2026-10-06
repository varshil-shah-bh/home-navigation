import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'map_data.dart';

/// Google Maps palette.
abstract final class GColors {
  static const blue = Color(0xFF1A73E8);
  static const blueDark = Color(0xFF1557B0);
  static const red = Color(0xFFEA4335);
  static const redDark = Color(0xFFB31412);
  static const green = Color(0xFF188038);
  static const navGreen = Color(0xFF137333);
  static const navGreenDark = Color(0xFF0D652D);
  static const land = Color(0xFFF1F3F4);
  static const building = Color(0xFFE3E5E8);
  static const buildingEdge = Color(0xFFBDC1C6);
  static const wall = Color(0xFFC8CBD0);
  static const text = Color(0xFF3C4043);
  static const textMuted = Color(0xFF5F6368);

  /// Marks people who need assistance (employees with a disability).
  static const assist = Color(0xFF7B1FA2);

  /// Marks volunteers on the emergency response team.
  static const responder = Color(0xFF0A2A66);
}

/// Visual category of a room, mirroring Google's POI colour coding.
class RoomStyle {
  final IconData icon;
  final Color fill;
  final Color accent;
  final bool walkway;

  const RoomStyle(this.icon, this.fill, this.accent, {this.walkway = false});

  static RoomStyle of(String roomId) {
    if (roomId.startsWith('bedroom')) {
      return const RoomStyle(Icons.bed, Color(0xFFF3EEFB), Color(0xFF8E63CE));
    }
    if (roomId.startsWith('toilet')) {
      return const RoomStyle(Icons.wc, Color(0xFFE8F0FE), Color(0xFF1A73E8));
    }
    if (roomId.startsWith('hall')) {
      return const RoomStyle(Icons.weekend, Color(0xFFFEF7E0), Color(0xFFE37400));
    }
    if (roomId.startsWith('passage')) {
      return const RoomStyle(
        Icons.directions_walk,
        Colors.white,
        GColors.textMuted,
        walkway: true,
      );
    }
    return const RoomStyle(Icons.meeting_room, Color(0xFFF8F9FA), GColors.textMuted);
  }
}

/// Converts between metres (map space) and pixels (canvas space).
class MapProjection {
  /// Pixels per metre.
  final double scale;

  /// Map-space point that is drawn at the canvas origin + [padding].
  final Offset mapOrigin;

  /// Pixel padding around the plan.
  final double padding;

  const MapProjection({
    required this.scale,
    required this.mapOrigin,
    this.padding = 40,
  });

  Offset toPixels(Offset metres) =>
      (metres - mapOrigin) * scale + Offset(padding, padding);

  Offset toMetres(Offset pixels) =>
      (pixels - Offset(padding, padding)) / scale + mapOrigin;

  Size canvasSize(MapData map) => Size(
    map.bounds.right * scale + padding * 2,
    map.bounds.bottom * scale + padding * 2,
  );
}

class MapPainter extends CustomPainter {
  final MapData map;
  final MapProjection projection;

  /// User position in metres.
  final Offset? user;

  /// Direction the user is facing / should walk, in radians (0 = +x).
  final double? heading;

  /// Route polyline in metres.
  final List<Offset> route;

  final String? highlightedRoomId;
  final bool showBeacons;

  /// Hidden while tracking live, where the user marker already sits on it.
  final bool showStartMarker;

  /// Draws direction chevrons on the route, as in turn-by-turn mode.
  final bool navigating;

  /// Estimated position error in metres, drawn as a halo around [user].
  final double accuracyInMetres;

  /// Measured beacon ranges in metres, drawn as rings.
  final List<(Offset, double)> ranges;

  const MapPainter({
    required this.map,
    required this.projection,
    this.user,
    this.heading,
    this.route = const [],
    this.highlightedRoomId,
    this.showBeacons = false,
    this.showStartMarker = true,
    this.navigating = false,
    this.accuracyInMetres = 0,
    this.ranges = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintBuilding(canvas);
    _paintRooms(canvas);
    _paintDoorOpenings(canvas);
    _paintRanges(canvas);
    _paintRoute(canvas);
    _paintLabels(canvas);
    _paintExits(canvas);
    if (showBeacons) _paintBeacons(canvas);
    _paintUser(canvas);
    _paintDestination(canvas);
  }

  Path _roomPath(Room room) =>
      Path()..addPolygon(room.polygon.map(projection.toPixels).toList(), true);

  /// The union of rooms, thickened, reads as one building footprint.
  void _paintBuilding(Canvas canvas) {
    final outline = Paint()
      ..color = GColors.buildingEdge
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeJoin = StrokeJoin.miter;
    final band = Paint()
      ..color = GColors.building
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13
      ..strokeJoin = StrokeJoin.miter;

    for (final room in map.rooms) {
      canvas.drawShadow(_roomPath(room), const Color(0x55000000), 6, false);
    }
    for (final room in map.rooms) {
      canvas.drawPath(_roomPath(room), outline);
    }
    for (final room in map.rooms) {
      canvas.drawPath(_roomPath(room), band);
    }
  }

  void _paintRooms(Canvas canvas) {
    final wall = Paint()
      ..color = GColors.wall
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (final room in map.rooms) {
      final style = RoomStyle.of(room.id);
      final path = _roomPath(room);
      canvas.drawPath(path, Paint()..color = style.fill);
      if (room.id == highlightedRoomId) {
        canvas.drawPath(path, Paint()..color = const Color(0x1F1A73E8));
      }
      canvas.drawPath(path, wall);
    }
  }

  /// Breaks the wall line at every doorway so openings read like Google's indoor maps.
  void _paintDoorOpenings(Canvas canvas) {
    final gap = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.butt;
    for (final door in map.doors) {
      final horizontal = _isHorizontalDoor(door);
      const half = 0.38;
      final a = door.position +
          (horizontal ? const Offset(-half, 0) : const Offset(0, -half));
      final b = door.position +
          (horizontal ? const Offset(half, 0) : const Offset(0, half));
      canvas.drawLine(projection.toPixels(a), projection.toPixels(b), gap);
    }
  }

  bool _isHorizontalDoor(Door door) {
    final from = map.roomById(door.from);
    final to = map.roomById(door.to);
    if (from == null || to == null) return true;
    return (from.center.dy - to.center.dy).abs() >
        (from.center.dx - to.center.dx).abs();
  }

  void _paintLabels(Canvas canvas) {
    for (final room in map.rooms) {
      final style = RoomStyle.of(room.id);
      final c = projection.toPixels(room.center);

      if (style.walkway) {
        final tp = _haloText(
          room.name,
          TextStyle(
            color: GColors.textMuted,
            fontSize: 10,
            fontStyle: FontStyle.italic,
            letterSpacing: 0.3,
          ),
        );
        canvas.save();
        canvas.translate(c.dx, c.dy);
        // Narrow corridors are labelled along their length.
        if (room.bounds.height > room.bounds.width * 1.5) {
          canvas.rotate(-math.pi / 2);
        }
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
        continue;
      }

      const r = 11.0;
      final iconCentre = c - const Offset(0, 9);
      canvas.drawCircle(
        iconCentre + const Offset(0, 1),
        r + 1,
        Paint()..color = const Color(0x33000000),
      );
      canvas.drawCircle(iconCentre, r + 1.5, Paint()..color = Colors.white);
      canvas.drawCircle(iconCentre, r, Paint()..color = style.accent);
      _paintIcon(canvas, style.icon, iconCentre, 13, Colors.white);

      final tp = _haloText(
        room.name,
        TextStyle(
          color: Color.lerp(style.accent, Colors.black, 0.35),
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      );
      tp.paint(canvas, Offset(c.dx - tp.width / 2, iconCentre.dy + r + 3));
    }
  }

  void _paintExits(Canvas canvas) {
    for (final exit in map.exits) {
      final p = projection.toPixels(exit.position);
      canvas.drawCircle(p, 13, Paint()..color = Colors.white);
      canvas.drawCircle(p, 11, Paint()..color = GColors.green);
      _paintIcon(canvas, Icons.door_front_door, p, 13, Colors.white);
      final tp = _haloText(
        exit.name,
        const TextStyle(
          color: GColors.green,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      );
      tp.paint(canvas, p + Offset(-tp.width / 2, 15));
    }
  }

  void _paintBeacons(Canvas canvas) {
    for (final beacon in map.beacons) {
      final p = projection.toPixels(beacon.position);
      canvas.drawCircle(p, 9, Paint()..color = Colors.white);
      canvas.drawCircle(
        p,
        7,
        Paint()
          ..color = beacon.deployed ? const Color(0xFF00897B) : GColors.wall,
      );
      _paintIcon(canvas, Icons.bluetooth, p, 9, Colors.white);
    }
  }

  void _paintRanges(Canvas canvas) {
    if (ranges.isEmpty) return;
    final stroke = Paint()
      ..color = const Color(0x4400897B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final (centre, metres) in ranges) {
      canvas.drawCircle(
        projection.toPixels(centre),
        metres * projection.scale,
        stroke,
      );
    }
  }

  void _paintRoute(Canvas canvas) {
    if (route.length < 2) return;
    final pixels = route.map(projection.toPixels).toList();
    final path = Path()..moveTo(pixels.first.dx, pixels.first.dy);
    for (final p in pixels.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }

    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, stroke(GColors.blueDark, 11));
    canvas.drawPath(path, stroke(GColors.blue, 7.5));

    if (navigating) _paintChevrons(canvas, pixels);

    if (showStartMarker) {
      final s = pixels.first;
      canvas.drawCircle(s, 8, Paint()..color = GColors.text);
      canvas.drawCircle(s, 5.5, Paint()..color = Colors.white);
    }
  }

  void _paintChevrons(Canvas canvas, List<Offset> pixels) {
    const spacing = 34.0;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    var carry = spacing / 2;
    for (var i = 1; i < pixels.length; i++) {
      final a = pixels[i - 1];
      final b = pixels[i];
      final seg = b - a;
      final length = seg.distance;
      if (length < 1) continue;
      final dir = seg / length;
      final normal = Offset(-dir.dy, dir.dx);
      var t = carry;
      while (t < length) {
        final p = a + dir * t;
        final tip = p + dir * 2.5;
        final back = p - dir * 2.5;
        canvas.drawPath(
          Path()
            ..moveTo(back.dx + normal.dx * 3, back.dy + normal.dy * 3)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo(back.dx - normal.dx * 3, back.dy - normal.dy * 3),
          paint,
        );
        t += spacing;
      }
      carry = t - length;
    }
  }

  /// Google's red teardrop pin, tip anchored on the destination.
  void _paintDestination(Canvas canvas) {
    if (route.length < 2) return;
    final tip = projection.toPixels(route.last);
    const r = 12.0;
    final head = tip - const Offset(0, 28);

    canvas.drawOval(
      Rect.fromCenter(center: tip, width: 12, height: 5),
      Paint()..color = const Color(0x55000000),
    );

    final pin = Path()
      ..moveTo(tip.dx, tip.dy)
      ..cubicTo(
        tip.dx - 3,
        tip.dy - 8,
        head.dx - r,
        head.dy + r * 0.9,
        head.dx - r,
        head.dy,
      )
      ..arcToPoint(
        Offset(head.dx + r, head.dy),
        radius: const Radius.circular(r),
      )
      ..cubicTo(
        head.dx + r,
        head.dy + r * 0.9,
        tip.dx + 3,
        tip.dy - 8,
        tip.dx,
        tip.dy,
      )
      ..close();

    canvas.drawShadow(pin, Colors.black, 3, false);
    canvas.drawPath(pin, Paint()..color = GColors.red);
    canvas.drawPath(
      pin,
      Paint()
        ..color = GColors.redDark
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawCircle(head, 4.5, Paint()..color = const Color(0xFF8C0E0B));
  }

  /// Blue location dot with accuracy disc and heading beam.
  void _paintUser(Canvas canvas) {
    if (user == null) return;
    final p = projection.toPixels(user!);

    if (accuracyInMetres > 0) {
      final r = accuracyInMetres * projection.scale;
      canvas.drawCircle(p, r, Paint()..color = const Color(0x221A73E8));
      canvas.drawCircle(
        p,
        r,
        Paint()
          ..color = const Color(0x551A73E8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    final h = heading;
    if (h != null) {
      const beam = 46.0;
      const spread = 0.62;
      final rect = Rect.fromCircle(center: p, radius: beam);
      canvas.drawPath(
        Path()
          ..moveTo(p.dx, p.dy)
          ..arcTo(rect, h - spread, spread * 2, false)
          ..close(),
        Paint()
          ..shader = RadialGradient(
            colors: const [Color(0x991A73E8), Color(0x001A73E8)],
          ).createShader(rect),
      );
    }

    canvas.drawCircle(
      p + const Offset(0, 1),
      12,
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(p, 11, Paint()..color = Colors.white);
    canvas.drawCircle(p, 8, Paint()..color = GColors.blue);
  }

  void _paintIcon(
    Canvas canvas,
    IconData icon,
    Offset centre,
    double size,
    Color color,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
  }

  /// Text with a white outline, as used for every label on Google Maps.
  TextPainter _haloText(String value, TextStyle style) => _Halo(value, style);

  @override
  bool shouldRepaint(MapPainter old) =>
      old.map != map ||
      old.user != user ||
      old.heading != heading ||
      old.route != route ||
      old.highlightedRoomId != highlightedRoomId ||
      old.showBeacons != showBeacons ||
      old.showStartMarker != showStartMarker ||
      old.navigating != navigating ||
      old.accuracyInMetres != accuracyInMetres ||
      old.ranges != ranges ||
      old.projection.scale != projection.scale;
}

/// Paints a stroked halo and the filled text on top, at the same origin.
class _Halo extends TextPainter {
  _Halo(String value, TextStyle style)
    : _fill = TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: TextDirection.ltr,
      )..layout(),
      super(
        text: TextSpan(
          text: value,
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..strokeJoin = StrokeJoin.round
              ..color = Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      ) {
    layout();
  }

  final TextPainter _fill;

  @override
  void paint(Canvas canvas, Offset offset) {
    super.paint(canvas, offset);
    _fill.paint(canvas, offset);
  }
}
