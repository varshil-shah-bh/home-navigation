import 'dart:convert';

import 'package:flutter/services.dart';

Offset _pt(List<dynamic> p) =>
    Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());

class Room {
  final String id;
  final String name;
  final List<Offset> polygon;

  const Room({required this.id, required this.name, required this.polygon});

  factory Room.fromJson(Map<String, dynamic> j) => Room(
    id: j['id'] as String,
    name: j['name'] as String,
    polygon: (j['polygon'] as List).map((p) => _pt(p as List)).toList(),
  );

  Rect get bounds {
    var left = polygon.first.dx, right = polygon.first.dx;
    var top = polygon.first.dy, bottom = polygon.first.dy;
    for (final p in polygon) {
      if (p.dx < left) left = p.dx;
      if (p.dx > right) right = p.dx;
      if (p.dy < top) top = p.dy;
      if (p.dy > bottom) bottom = p.dy;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Offset get center => bounds.center;

  /// Ray-casting point-in-polygon test, in metres.
  bool contains(Offset p) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i], b = polygon[j];
      final intersects = (a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx;
      if (intersects) inside = !inside;
    }
    return inside;
  }
}

class Door {
  final String id;
  final String from;
  final String to;
  final Offset position;

  const Door({
    required this.id,
    required this.from,
    required this.to,
    required this.position,
  });

  factory Door.fromJson(Map<String, dynamic> j) => Door(
    id: j['id'] as String,
    from: j['from'] as String,
    to: j['to'] as String,
    position: _pt(j['position'] as List),
  );
}

class ExitPoint {
  final String id;
  final String name;
  final String room;
  final Offset position;

  const ExitPoint({
    required this.id,
    required this.name,
    required this.room,
    required this.position,
  });

  factory ExitPoint.fromJson(Map<String, dynamic> j) => ExitPoint(
    id: j['id'] as String,
    name: j['name'] as String,
    room: j['room'] as String,
    position: _pt(j['position'] as List),
  );
}

class Beacon {
  final String id;
  final Offset position;

  /// Room the beacon is mounted in, used for room-level fallback.
  final String? room;

  /// iBeacon identifiers. [txPower] is the calibrated RSSI at 1 m.
  final int major;
  final int minor;
  final int txPower;

  /// False for planned positions that have no hardware installed yet.
  final bool deployed;

  const Beacon({
    required this.id,
    required this.position,
    this.room,
    this.major = 0,
    this.minor = 0,
    this.txPower = -59,
    this.deployed = false,
  });

  factory Beacon.fromJson(Map<String, dynamic> j) => Beacon(
    id: j['id'] as String,
    position: _pt(j['position'] as List),
    room: j['room'] as String?,
    major: (j['major'] as num?)?.toInt() ?? 0,
    minor: (j['minor'] as num?)?.toInt() ?? 0,
    txPower: (j['txPower'] as num?)?.toInt() ?? -59,
    deployed: j['deployed'] as bool? ?? false,
  );
}

class MapData {
  final String name;
  final String unit;

  /// Proximity UUID shared by every beacon in this home.
  final String beaconUuid;
  final List<Room> rooms;
  final List<Door> doors;
  final List<ExitPoint> exits;
  final List<Beacon> beacons;

  const MapData({
    required this.name,
    required this.unit,
    required this.beaconUuid,
    required this.rooms,
    required this.doors,
    required this.exits,
    required this.beacons,
  });

  factory MapData.fromJson(Map<String, dynamic> j) => MapData(
    name: j['name'] as String? ?? 'map',
    unit: j['unit'] as String? ?? 'm',
    beaconUuid: j['beaconUuid'] as String? ?? '',
    rooms: (j['rooms'] as List)
        .map((r) => Room.fromJson(r as Map<String, dynamic>))
        .toList(),
    doors: (j['doors'] as List)
        .map((d) => Door.fromJson(d as Map<String, dynamic>))
        .toList(),
    exits: (j['exits'] as List)
        .map((e) => ExitPoint.fromJson(e as Map<String, dynamic>))
        .toList(),
    beacons: (j['beacons'] as List)
        .map((b) => Beacon.fromJson(b as Map<String, dynamic>))
        .toList(),
  );

  static Future<MapData> load(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return MapData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Bounding box of the whole floor plan, in metres.
  Rect get bounds =>
      rooms.map((r) => r.bounds).reduce((a, b) => a.expandToInclude(b));

  Room? roomAt(Offset pointInMetres) {
    for (final r in rooms) {
      if (r.contains(pointInMetres)) return r;
    }
    return null;
  }

  Room? roomById(String id) {
    for (final r in rooms) {
      if (r.id == id) return r;
    }
    return null;
  }
}
