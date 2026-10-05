import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../map/map_data.dart';
import '../map/map_navigator.dart';
import 'beacon_scanner.dart';
import 'ibeacon.dart';

/// One map beacon currently in range, with a smoothed distance estimate.
class BeaconFix {
  final Beacon beacon;
  final double rssi;
  final double distance;
  final DateTime seenAt;

  const BeaconFix({
    required this.beacon,
    required this.rssi,
    required this.distance,
    required this.seenAt,
  });
}

enum FixMethod { none, nearest, weighted, trilateration }

class PositionFix {
  final Offset? point;
  final String? roomId;

  /// Rough 1-sigma error in metres.
  final double accuracy;
  final FixMethod method;
  final List<BeaconFix> used;

  const PositionFix({
    this.point,
    this.roomId,
    this.accuracy = 0,
    this.method = FixMethod.none,
    this.used = const [],
  });

  String get label => switch (method) {
    FixMethod.none => 'No beacons in range',
    FixMethod.nearest => 'Room level (1 beacon)',
    FixMethod.weighted => 'Approximate (2 beacons)',
    FixMethod.trilateration => 'Trilaterated (${used.length} beacons)',
  };
}

/// Turns live beacon readings into a position on the floor plan.
class PositionEngine extends ChangeNotifier {
  PositionEngine({
    required this.map,
    required this.scanner,
    this.navigator,
  }) {
    scanner.addListener(_onScan);
  }

  final MapData map;
  final BeaconScanner scanner;

  /// When supplied, the reported position is kept on walkable ground and may
  /// only move between rooms by passing through a doorway.
  final MapNavigator? navigator;

  /// Exponential smoothing factor for RSSI. Lower is steadier but laggier.
  static const _alpha = 0.18;

  /// Readings older than this are ignored.
  static const _staleAfter = Duration(seconds: 8);

  /// Indoor path-loss exponent. Raise it if distances read too long.
  double pathLoss = 2.8;

  /// Upper bound on how fast the marker may travel, in metres per second.
  double maxSpeed = 1.4;

  Offset? _previousPoint;
  DateTime? _previousAt;

  /// Reported accuracy is capped: RSSI ranging cannot justify a halo larger
  /// than a room, and an oversized one just hides the estimate.
  static const _minAccuracy = 0.8;
  static const _maxAccuracy = 3.5;

  final Map<String, double> _smoothedRssi = {};
  final Map<String, DateTime> _lastSeen = {};

  /// Radio addresses seen advertising each map beacon id.
  final Map<String, Set<String>> _sources = {};

  /// Beacon ids that more than one device is currently claiming.
  List<String> get conflicts => [
    for (final e in _sources.entries)
      if (e.value.length > 1) e.key,
  ];

  PositionFix _fix = const PositionFix();
  PositionFix get fix => _fix;

  void _onScan() {
    for (final observation in scanner.devices) {
      final reading = observation.beacon;
      if (reading == null) continue;
      final beacon = _match(reading);
      if (beacon == null) continue;

      (_sources[beacon.id] ??= {}).add(observation.deviceId);

      final previous = _smoothedRssi[beacon.id];
      _smoothedRssi[beacon.id] = previous == null
          ? reading.rssi.toDouble()
          : previous + _alpha * (reading.rssi - previous);
      _lastSeen[beacon.id] = observation.seenAt;
    }
    _recompute();
  }

  Beacon? _match(IBeaconReading reading) {
    if (map.beaconUuid.isNotEmpty &&
        reading.uuid.toLowerCase() != map.beaconUuid.toLowerCase()) {
      return null;
    }
    for (final b in map.beacons) {
      if (b.major == reading.major && b.minor == reading.minor) return b;
    }
    return null;
  }

  void reset() {
    _smoothedRssi.clear();
    _lastSeen.clear();
    _sources.clear();
    _previousPoint = null;
    _previousAt = null;
    _fix = const PositionFix();
    notifyListeners();
  }

  void _recompute() {
    final now = DateTime.now();
    final fixes = <BeaconFix>[];

    for (final beacon in map.beacons) {
      final rssi = _smoothedRssi[beacon.id];
      final seen = _lastSeen[beacon.id];
      if (rssi == null || seen == null) continue;
      if (now.difference(seen) > _staleAfter) continue;
      fixes.add(
        BeaconFix(
          beacon: beacon,
          rssi: rssi,
          distance: _distance(beacon.txPower, rssi),
          seenAt: seen,
        ),
      );
    }

    fixes.sort((a, b) => a.distance.compareTo(b.distance));
    final raw = _solve(fixes);
    _fix = raw.point == null
        ? raw
        : PositionFix(
            point: _constrain(raw.point!),
            roomId: raw.roomId,
            accuracy: raw.accuracy,
            method: raw.method,
            used: raw.used,
          );
    final settled = _fix.point;
    if (settled != null) {
      _fix = PositionFix(
        point: settled,
        roomId: map.roomAt(settled)?.id ?? _fix.roomId,
        accuracy: _fix.accuracy,
        method: _fix.method,
        used: _fix.used,
      );
    }
    notifyListeners();
  }

  /// Keeps the marker on walkable ground: it may only reach a new room by
  /// travelling through doorways, and never faster than [maxSpeed].
  Offset _constrain(Offset candidate) {
    final now = DateTime.now();
    final previous = _previousPoint;
    final nav = navigator;

    if (previous == null || nav == null) {
      _previousPoint = candidate;
      _previousAt = now;
      return candidate;
    }

    final elapsed = now.difference(_previousAt ?? now).inMilliseconds / 1000;
    final budget = math.max(0.25, maxSpeed * elapsed);

    Offset target;
    if (nav.hasLineOfSight(previous, candidate)) {
      final delta = candidate - previous;
      target = delta.distance <= budget
          ? candidate
          : previous + delta / delta.distance * budget;
    } else {
      // Walls in between: follow the door-to-door route instead of cutting through.
      final path = nav.route(previous, candidate).points;
      target = path.length < 2 ? previous : _advanceAlong(path, budget);
    }

    _previousPoint = target;
    _previousAt = now;
    return target;
  }

  /// Walks [budget] metres along [path] from its first point.
  Offset _advanceAlong(List<Offset> path, double budget) {
    var remaining = budget;
    var current = path.first;
    for (var i = 1; i < path.length; i++) {
      final segment = path[i] - current;
      final length = segment.distance;
      if (length <= remaining) {
        remaining -= length;
        current = path[i];
        continue;
      }
      return current + segment / length * remaining;
    }
    return current;
  }

  double _distance(int txPower, double rssi) =>
      math.pow(10, (txPower - rssi) / (10 * pathLoss)).toDouble();

  PositionFix _solve(List<BeaconFix> fixes) {
    if (fixes.isEmpty) return const PositionFix();

    if (fixes.length == 1) {
      final only = fixes.first;
      final room = only.beacon.room == null
          ? map.roomAt(only.beacon.position)
          : map.roomById(only.beacon.room!);
      return PositionFix(
        point: room?.center ?? only.beacon.position,
        roomId: room?.id,
        accuracy: (only.distance * 0.6).clamp(_minAccuracy, _maxAccuracy),
        method: FixMethod.nearest,
        used: fixes,
      );
    }

    // Inverse-distance weighted centroid: usable on its own, and the seed for
    // the least-squares solve below.
    var sum = Offset.zero;
    var weightTotal = 0.0;
    for (final f in fixes) {
      final w = 1 / math.max(f.distance * f.distance, 0.25);
      sum += f.beacon.position * w;
      weightTotal += w;
    }
    final centroid = sum / weightTotal;

    if (fixes.length == 2) {
      final snapped = _snap(centroid);
      return PositionFix(
        point: snapped,
        roomId: map.roomAt(snapped)?.id,
        // The closest beacon bounds the error far better than the average.
        accuracy: (fixes.first.distance * 0.6).clamp(
          _minAccuracy,
          _maxAccuracy,
        ),
        method: FixMethod.weighted,
        used: fixes,
      );
    }

    final solved = _leastSquares(centroid, fixes);
    final snapped = _snap(solved);
    return PositionFix(
      point: snapped,
      roomId: map.roomAt(snapped)?.id,
      accuracy: _residual(solved, fixes).clamp(_minAccuracy, _maxAccuracy),
      method: FixMethod.trilateration,
      used: fixes,
    );
  }

  /// Gauss-Newton refinement of the centroid against the measured ranges.
  Offset _leastSquares(Offset seed, List<BeaconFix> fixes) {
    var p = seed;
    for (var iteration = 0; iteration < 24; iteration++) {
      var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0;

      for (final f in fixes) {
        final d = p - f.beacon.position;
        final range = d.distance;
        if (range < 1e-6) continue;
        final jx = d.dx / range;
        final jy = d.dy / range;
        final residual = range - f.distance;
        final w = 1 / math.max(f.distance * f.distance, 0.25);

        a11 += w * jx * jx;
        a12 += w * jx * jy;
        a22 += w * jy * jy;
        b1 -= w * jx * residual;
        b2 -= w * jy * residual;
      }

      final det = a11 * a22 - a12 * a12;
      if (det.abs() < 1e-9) break;
      final dx = (b1 * a22 - a12 * b2) / det;
      final dy = (a11 * b2 - b1 * a12) / det;
      p += Offset(dx, dy);
      if (dx.abs() + dy.abs() < 1e-4) break;
    }
    return p;
  }

  double _residual(Offset p, List<BeaconFix> fixes) {
    var sum = 0.0;
    for (final f in fixes) {
      final e = (p - f.beacon.position).distance - f.distance;
      sum += e * e;
    }
    return math.sqrt(sum / fixes.length);
  }

  /// Pulls a solution that landed inside a wall back into the nearest room.
  Offset _snap(Offset p) {
    if (map.roomAt(p) != null) return p;

    Offset? best;
    var bestDistance = double.infinity;
    for (final room in map.rooms) {
      final b = room.bounds;
      final clamped = Offset(
        p.dx.clamp(b.left + 0.05, b.right - 0.05),
        p.dy.clamp(b.top + 0.05, b.bottom - 0.05),
      );
      final d = (clamped - p).distance;
      if (d < bestDistance) {
        bestDistance = d;
        best = clamped;
      }
    }
    return best ?? p;
  }

  @override
  void dispose() {
    scanner.removeListener(_onScan);
    super.dispose();
  }
}
