import 'dart:collection';
import 'dart:math';
import 'dart:ui';

import 'map_data.dart';

enum Maneuver { depart, straight, left, right, sharpLeft, sharpRight, uTurn, arrive }

/// One leg of a route: what to do, and how far to walk doing it.
class NavStep {
  final Maneuver maneuver;

  /// Short headline, e.g. "Turn right".
  final String title;

  /// Where the leg leads, e.g. "into Passage". May be empty.
  final String detail;

  /// Full sentence for the step list.
  final String text;

  /// Metres walked on this leg.
  final double distance;

  const NavStep({
    required this.maneuver,
    required this.title,
    required this.detail,
    required this.text,
    required this.distance,
  });
}

/// A computed walking route: the polyline to draw plus turn-by-turn steps.
class NavRoute {
  /// Polyline in metres.
  final List<Offset> points;

  final List<NavStep> instructions;

  const NavRoute({required this.points, required this.instructions});

  static const empty = NavRoute(points: [], instructions: []);

  List<String> get steps => [for (final s in instructions) s.text];

  bool get isEmpty => points.length < 2;

  double get lengthInMetres {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += (points[i] - points[i - 1]).distance;
    }
    return total;
  }
}

class _Waypoint {
  final Offset point;
  final Door? door;
  const _Waypoint(this.point, [this.door]);
}

/// Door-to-door walking graph.
///
/// Doors are the only fixed waypoints: two doors are connected when they open
/// into the same room. The resulting polyline is then string-pulled against the
/// wall segments so it becomes the direct line a person would actually walk.
class MapNavigator {
  final MapData map;

  /// Wall segments of every room, used for line-of-sight checks.
  final List<(Offset, Offset)> _walls = [];

  /// How far from a door centre a wall may be crossed, in metres.
  static const _doorHalfWidth = 0.45;

  MapNavigator(this.map) {
    for (final room in map.rooms) {
      for (var i = 0; i < room.polygon.length; i++) {
        _walls.add((room.polygon[i], room.polygon[(i + 1) % room.polygon.length]));
      }
    }
  }

  List<Door> _doorsOf(String roomId) => [
    for (final d in map.doors)
      if (d.from == roomId || d.to == roomId) d,
  ];

  /// Shortest walking route between two points of the plan. Returns
  /// [NavRoute.empty] when either point is outside every room or the rooms are
  /// not connected by doors.
  NavRoute route(Offset from, Offset to) {
    final fromRoom = map.roomAt(from);
    final toRoom = map.roomAt(to);
    if (fromRoom == null || toRoom == null) return NavRoute.empty;

    if (fromRoom.id == toRoom.id) {
      final direct = [_Waypoint(from), _Waypoint(to)];
      return _build(direct, fromRoom, toRoom.name);
    }

    final doors = _shortestDoorPath(from, fromRoom, to, toRoom);
    if (doors == null) return NavRoute.empty;

    final raw = [
      _Waypoint(from),
      for (final d in doors) _Waypoint(d.position, d),
      _Waypoint(to),
    ];
    return _build(_straighten(raw), fromRoom, toRoom.name);
  }

  /// Route from [from] to a named exit (e.g. the main door / safe zone).
  NavRoute routeToExit(Offset from, ExitPoint exit) {
    final room = map.roomById(exit.room);
    if (room == null) return NavRoute.empty;
    // Pull the target slightly inside its room so point-in-polygon succeeds.
    final inside = exit.position + (room.center - exit.position) * 0.02;
    final base = route(from, inside);
    if (base.isEmpty) return NavRoute.empty;
    return NavRoute(
      points: [...base.points, exit.position],
      instructions: [
        ...base.instructions.take(base.instructions.length - 1),
        NavStep(
          maneuver: Maneuver.arrive,
          title: 'Arrive at ${exit.name}',
          detail: 'Step outside',
          text: 'Step outside through the ${exit.name}.',
          distance: 0,
        ),
      ],
    );
  }

  /// Dijkstra over doors; returns the doors to pass through, in order.
  List<Door>? _shortestDoorPath(
    Offset from,
    Room fromRoom,
    Offset to,
    Room toRoom,
  ) {
    final byId = {for (final d in map.doors) d.id: d};
    final goals = _doorsOf(toRoom.id).map((d) => d.id).toSet();

    final dist = <String, double>{};
    final prev = <String, String?>{};
    // Records are not Comparable, so the priority ordering is explicit.
    final queue = SplayTreeMap<(double, String), String>((a, b) {
      final byCost = a.$1.compareTo(b.$1);
      return byCost != 0 ? byCost : a.$2.compareTo(b.$2);
    });

    for (final d in _doorsOf(fromRoom.id)) {
      final cost = (d.position - from).distance;
      dist[d.id] = cost;
      prev[d.id] = null;
      queue[(cost, d.id)] = d.id;
    }

    String? goal;
    var best = double.infinity;
    while (queue.isNotEmpty) {
      final entry = queue.firstKey()!;
      queue.remove(entry);
      final id = entry.$2;
      if (entry.$1 > (dist[id] ?? double.infinity)) continue;

      if (goals.contains(id)) {
        final total = dist[id]! + (byId[id]!.position - to).distance;
        if (total < best) {
          best = total;
          goal = id;
        }
        continue;
      }

      final door = byId[id]!;
      for (final roomId in [door.from, door.to]) {
        for (final next in _doorsOf(roomId)) {
          if (next.id == id) continue;
          final cost =
              dist[id]! + (next.position - door.position).distance;
          if (cost < (dist[next.id] ?? double.infinity)) {
            dist[next.id] = cost;
            prev[next.id] = id;
            queue[(cost, next.id)] = next.id;
          }
        }
      }
    }
    if (goal == null) return null;

    final path = <Door>[];
    for (String? id = goal; id != null; id = prev[id]) {
      path.insert(0, byId[id]!);
    }
    return path;
  }

  /// Drops waypoints that can be skipped with a straight, wall-free walk.
  List<_Waypoint> _straighten(List<_Waypoint> points) {
    final result = [points.first];
    var i = 0;
    while (i < points.length - 1) {
      var next = i + 1;
      for (var j = points.length - 1; j > i + 1; j--) {
        if (hasLineOfSight(points[i].point, points[j].point)) {
          next = j;
          break;
        }
      }
      result.add(points[next]);
      i = next;
    }
    return result;
  }

  /// True when a straight walk from [a] to [b] only crosses walls at doorways.
  bool hasLineOfSight(Offset a, Offset b) {
    for (final wall in _walls) {
      final hit = _intersection(a, b, wall.$1, wall.$2);
      if (hit == null) continue;
      final atEnd = (hit - a).distance < 1e-6 || (hit - b).distance < 1e-6;
      if (atEnd) continue;
      final throughDoor = map.doors.any(
        (d) => (d.position - hit).distance <= _doorHalfWidth,
      );
      if (!throughDoor) return false;
    }
    return true;
  }

  /// Proper intersection point of segments p->p2 and q->q2, or null.
  Offset? _intersection(Offset p, Offset p2, Offset q, Offset q2) {
    final r = p2 - p;
    final s = q2 - q;
    final denom = r.dx * s.dy - r.dy * s.dx;
    if (denom.abs() < 1e-9) return null;
    final qp = q - p;
    final t = (qp.dx * s.dy - qp.dy * s.dx) / denom;
    final u = (qp.dx * r.dy - qp.dy * r.dx) / denom;
    if (t < 0 || t > 1 || u < 0 || u > 1) return null;
    return p + r * t;
  }

  NavRoute _build(List<_Waypoint> way, Room startRoom, String destination) {
    final points = way.map((w) => w.point).toList();
    return NavRoute(
      points: points,
      instructions: _directions(way, startRoom, destination),
    );
  }

  /// Turn-by-turn steps derived from the geometry of the walked polyline.
  List<NavStep> _directions(
    List<_Waypoint> way,
    Room startRoom,
    String destination,
  ) {
    if (way.length < 2) return const [];

    final steps = <NavStep>[];
    Offset? previousHeading;

    for (var i = 0; i < way.length - 1; i++) {
      final a = way[i].point;
      final b = way[i + 1].point;
      final delta = b - a;
      final distance = delta.distance;
      if (distance < 0.05) continue;
      final heading = delta / distance;

      final maneuver = previousHeading == null
          ? Maneuver.depart
          : _turn(previousHeading, heading);
      previousHeading = heading;

      final door = way[i + 1].door;
      final isLastLeg = i + 2 == way.length;
      final nextRoom = door != null
          ? _roomAfter(door, a)
          : map.roomAt(b)?.name ?? destination;
      final detail = door != null
          ? 'into $nextRoom'
          : isLastLeg
          ? 'towards $destination'
          : 'towards $nextRoom';
      final target = door != null
          ? 'through the doorway into $nextRoom'
          : isLastLeg
          ? 'to reach $destination'
          : 'ahead';
      final move = maneuver == Maneuver.depart
          ? 'From ${startRoom.name}, walk'
          : '${_maneuverTitle(maneuver)} and walk';

      steps.add(
        NavStep(
          maneuver: maneuver,
          title: maneuver == Maneuver.depart
              ? 'Head out of ${startRoom.name}'
              : _maneuverTitle(maneuver),
          detail: detail,
          text: '$move ${distance.toStringAsFixed(1)} m $target.',
          distance: distance,
        ),
      );
    }

    steps.add(
      NavStep(
        maneuver: Maneuver.arrive,
        title: steps.isEmpty ? 'You are here' : 'Arrive at $destination',
        detail: destination,
        text: steps.isEmpty
            ? 'You are already at $destination.'
            : '$destination reached.',
        distance: 0,
      ),
    );
    return steps;
  }

  static String _maneuverTitle(Maneuver m) => switch (m) {
    Maneuver.depart => 'Head out',
    Maneuver.straight => 'Continue straight',
    Maneuver.left => 'Turn left',
    Maneuver.right => 'Turn right',
    Maneuver.sharpLeft => 'Take a sharp left',
    Maneuver.sharpRight => 'Take a sharp right',
    Maneuver.uTurn => 'Turn around',
    Maneuver.arrive => 'Arrive',
  };

  Maneuver _turn(Offset from, Offset to) {
    final dot = (from.dx * to.dx + from.dy * to.dy).clamp(-1.0, 1.0);
    final degrees = acos(dot) * 180 / pi;
    if (degrees < 20) return Maneuver.straight;
    if (degrees > 150) return Maneuver.uTurn;
    // y grows downwards, so a positive cross product is a clockwise turn.
    final right = from.dx * to.dy - from.dy * to.dx > 0;
    if (degrees > 115) return right ? Maneuver.sharpRight : Maneuver.sharpLeft;
    return right ? Maneuver.right : Maneuver.left;
  }

  /// The room on the far side of [door] when approaching from [origin].
  String _roomAfter(Door door, Offset origin) {
    final from = map.roomById(door.from);
    final to = map.roomById(door.to);
    if (from == null || to == null) return door.to;
    final entered = from.contains(origin) ? to : from;
    return entered.name;
  }
}
