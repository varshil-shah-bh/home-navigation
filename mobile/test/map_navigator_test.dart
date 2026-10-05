import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_poc/map/map_data.dart';
import 'package:home_poc/map/map_navigator.dart';

void main() {
  late MapData map;
  late MapNavigator nav;

  setUpAll(() {
    final raw = File('assets/home_map.json').readAsStringSync();
    map = MapData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    nav = MapNavigator(map);
  });

  test('routes between rooms through doors', () {
    final from = map.roomById('bedroom2')!.center;
    final to = map.roomById('hall')!.center;

    final route = nav.route(from, to);

    expect(route.isEmpty, isFalse);
    expect(route.lengthInMetres, greaterThan(0));
    expect(route.points.first, from);
    expect(route.points.last, to);
    expect(route.steps.first, startsWith('From Bedroom 2, walk'));
    expect(route.steps.last, contains('Hall'));
  });

  test('every leg stays inside the plan or passes a doorway', () {
    final route = nav.route(
      map.roomById('bedroom2')!.center,
      map.roomById('bedroom1')!.center,
    );

    expect(route.isEmpty, isFalse);
    for (var i = 0; i < route.points.length - 1; i++) {
      final a = route.points[i];
      final b = route.points[i + 1];
      for (var t = 1; t < 20; t++) {
        final p = a + (b - a) * (t / 20);
        final walkable = map.roomAt(p) != null ||
            map.doors.any((d) => (d.position - p).distance < 0.5);
        expect(walkable, isTrue, reason: 'leg $i escapes the plan at $p');
      }
    }
  });

  test('routes to the main door exit', () {
    final from = map.roomById('toilet1')!.center;
    final route = nav.routeToExit(from, map.exits.single);

    expect(route.isEmpty, isFalse);
    expect(route.points.last, const Offset(4.4, 9.0));
    expect(route.steps.last, contains('Main door'));
  });

  test('same-room route is direct', () {
    final room = map.roomById('bedroom1')!;
    final route = nav.route(room.center, room.center + const Offset(0.5, 0.5));

    expect(route.points, hasLength(2));
  });

  test('instructions start with depart and end with arrive', () {
    final route = nav.route(
      map.roomById('bedroom2')!.center,
      map.roomById('bedroom1')!.center,
    );

    expect(route.instructions.first.maneuver, Maneuver.depart);
    expect(route.instructions.last.maneuver, Maneuver.arrive);
    final walked = route.instructions.fold<double>(0, (s, i) => s + i.distance);
    expect(walked, closeTo(route.lengthInMetres, 1e-6));
  });
}
