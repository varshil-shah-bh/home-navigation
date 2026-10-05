import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ble/beacon_scanner.dart';
import '../ble/ble_debug_screen.dart';
import '../ble/position_engine.dart';
import 'map_data.dart';
import 'map_navigator.dart';
import 'map_painter.dart';

const _you = '__you__';

/// Indoor walking pace used for ETAs, in metres per second.
const _walkingSpeed = 1.2;

class MapView extends StatefulWidget {
  const MapView({super.key, this.assetPath = 'assets/home_map.json', this.onSignOut});

  final String assetPath;
  final VoidCallback? onSignOut;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with SingleTickerProviderStateMixin {
  static const _projection = MapProjection(scale: 70, mapOrigin: Offset.zero);

  final _controller = TransformationController();
  final _sheet = DraggableScrollableController();
  late final AnimationController _camera;
  Animation<Matrix4>? _cameraTween;

  MapData? _map;
  MapNavigator? _navigator;
  Object? _error;

  /// Current position in metres: tapped, or from BLE once live.
  Offset? _user;

  /// `null` means "start from [_user]".
  String? _sourceId;
  String? _destinationId;
  NavRoute _route = NavRoute.empty;

  bool _showBeacons = false;
  bool _didFit = false;
  bool _navigating = false;
  bool _follow = false;
  double _sheetExtent = 0.3;
  double? _movementHeading;
  Offset? _lastFollowed;
  Size _viewport = Size.zero;

  BeaconScanner? _scanner;
  PositionEngine? _engine;
  PositionFix _fix = const PositionFix();
  bool get _live => _engine != null;

  @override
  void initState() {
    super.initState();
    _camera =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 450),
        )..addListener(() {
          final tween = _cameraTween;
          if (tween != null) _controller.value = tween.value;
        });
    _load();
  }

  @override
  void dispose() {
    _engine?.dispose();
    _scanner?.dispose();
    _camera.dispose();
    _sheet.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final map = await MapData.load(widget.assetPath);
      if (!mounted) return;
      setState(() {
        _map = map;
        _navigator = MapNavigator(map);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  // --- routing -------------------------------------------------------------

  void _setUser(Offset metres) {
    if (_map?.roomAt(metres) == null) return;
    setState(() {
      final prev = _user;
      if (prev != null && (metres - prev).distance > 0.08) {
        final d = metres - prev;
        _movementHeading = math.atan2(d.dy, d.dx);
      }
      _user = metres;
      _sourceId = null;
      _recomputeRoute();
    });
    if (_follow) _followUser();
  }

  void _setSource(String? id) => setState(() {
    _sourceId = id == _you ? null : id;
    _recomputeRoute();
  });

  void _setDestination(String? id) {
    setState(() {
      _destinationId = id;
      _recomputeRoute();
    });
    if (!_route.isEmpty) _animateCamera(_fitMatrix());
  }

  void _swap() => setState(() {
    final from = _sourceId ?? _map?.roomAt(_user ?? Offset.zero)?.id;
    _sourceId = _destinationId;
    _destinationId = from;
    _recomputeRoute();
  });

  void _closeDirections() => setState(() {
    _destinationId = null;
    _sourceId = null;
    _route = NavRoute.empty;
  });

  Offset? _anchor(String id) {
    final map = _map;
    if (map == null) return null;
    final room = map.roomById(id);
    if (room != null) return room.center;
    for (final exit in map.exits) {
      if (exit.id == id) {
        final host = map.roomById(exit.room);
        if (host == null) return null;
        return exit.position + (host.center - exit.position) * 0.02;
      }
    }
    return null;
  }

  Offset? get _sourcePoint => _sourceId == null ? _user : _anchor(_sourceId!);

  void _recomputeRoute() {
    final map = _map, nav = _navigator, dest = _destinationId;
    final from = _sourcePoint;
    if (map == null || nav == null || from == null || dest == null) {
      _route = NavRoute.empty;
      return;
    }
    for (final exit in map.exits) {
      if (exit.id == dest) {
        _route = nav.routeToExit(from, exit);
        return;
      }
    }
    final room = map.roomById(dest);
    _route = room == null ? NavRoute.empty : nav.route(from, room.center);
  }

  String _labelFor(String? id) {
    final map = _map;
    if (id == null || map == null) return '';
    final room = map.roomById(id);
    if (room != null) return room.name;
    for (final e in map.exits) {
      if (e.id == id) return e.name;
    }
    return id;
  }

  double? get _heading {
    final pts = _route.points;
    if (pts.length >= 2) {
      final d = pts[1] - pts[0];
      if (d.distance > 0.05) return math.atan2(d.dy, d.dx);
    }
    return _live ? _movementHeading : null;
  }

  bool get _arrived =>
      _navigating && !_route.isEmpty && _route.lengthInMetres < 0.7;

  // --- navigation mode -----------------------------------------------------

  Future<void> _startNavigation() async {
    final start = _sourcePoint;
    setState(() {
      // Navigation always runs from "you", so a picked start becomes your position.
      if (start != null) _user = start;
      _sourceId = null;
      _recomputeRoute();
      _navigating = true;
      _follow = true;
    });
    if (start != null) _animateCamera(_followMatrix(start, scale: 1.8));
    if (!_live) await _toggleLive();
  }

  void _exitNavigation() {
    setState(() {
      _navigating = false;
      _follow = false;
      if (_arrived) {
        _destinationId = null;
        _route = NavRoute.empty;
      }
    });
    _animateCamera(_fitMatrix());
  }

  void _overview() {
    setState(() => _follow = false);
    _animateCamera(_fitMatrix());
  }

  // --- live positioning ----------------------------------------------------

  Future<void> _toggleLive() async {
    final map = _map;
    if (map == null) return;

    if (_live) {
      await _scanner?.stop();
      _engine?.removeListener(_onFix);
      _engine?.dispose();
      _scanner?.dispose();
      setState(() {
        _engine = null;
        _scanner = null;
        _fix = const PositionFix();
      });
      return;
    }

    final scanner = BeaconScanner(logEveryPacket: false);
    final engine = PositionEngine(
      map: map,
      scanner: scanner,
      navigator: _navigator,
    )..addListener(_onFix);
    setState(() {
      _scanner = scanner;
      _engine = engine;
    });
    await scanner.start();
    if (mounted) setState(() {});
  }

  void _onFix() {
    final fix = _engine?.fix;
    if (fix == null || !mounted) return;
    setState(() {
      _fix = fix;
      final point = fix.point;
      if (point != null) {
        final prev = _user;
        if (prev != null && (point - prev).distance > 0.08) {
          final d = point - prev;
          _movementHeading = math.atan2(d.dy, d.dx);
        }
        _user = point;
        _sourceId = null;
        _recomputeRoute();
      }
    });
    if (_follow) _followUser();
  }

  Future<void> _onMyLocation() async {
    if (!_live) await _toggleLive();
    setState(() => _follow = true);
    _lastFollowed = null;
    _followUser();
  }

  // --- camera --------------------------------------------------------------

  double get _topChrome {
    final pad = MediaQuery.paddingOf(context).top;
    if (_navigating) return pad + 150;
    if (_destinationId != null) return pad + 170;
    return pad + 120;
  }

  double get _bottomChrome {
    if (_navigating) return 110;
    if (!_route.isEmpty) return _viewport.height * 0.3;
    return 90;
  }

  Matrix4 _fitMatrix() {
    final map = _map!;
    final content = _projection.canvasSize(map);
    final top = _topChrome;
    final usable = math.max(160.0, _viewport.height - top - _bottomChrome);
    final s = math
        .min(_viewport.width / content.width, usable / content.height)
        .clamp(0.2, 2.0);
    final dx = (_viewport.width - content.width * s) / 2;
    final dy = top + (usable - content.height * s) / 2;
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  Matrix4 _followMatrix(Offset metres, {double? scale}) {
    final current = _controller.value.getMaxScaleOnAxis();
    final s = (scale ?? math.max(current, _navigating ? 1.8 : 1.3)).clamp(
      0.3,
      6.0,
    );
    final u = _projection.toPixels(metres);
    final top = _topChrome;
    final usable = math.max(120.0, _viewport.height - top - _bottomChrome);
    final v = Offset(_viewport.width / 2, top + usable * 0.6);
    final t = v - u * s;
    return Matrix4.identity()
      ..translateByDouble(t.dx, t.dy, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  void _followUser() {
    final u = _user;
    if (u == null) return;
    final last = _lastFollowed;
    if (last != null && (u - last).distance < 0.03) return;
    _lastFollowed = u;
    _animateCamera(_followMatrix(u));
  }

  void _animateCamera(Matrix4 target) {
    if (_viewport == Size.zero) return;
    _cameraTween = Matrix4Tween(
      begin: _controller.value.clone(),
      end: target,
    ).animate(CurvedAnimation(parent: _camera, curve: Curves.easeOutCubic));
    _camera.forward(from: 0);
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text('Map failed to load: $_error'));
    }
    final map = _map;
    if (map == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        if (!_didFit) {
          _didFit = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _controller.value = _fitMatrix();
          });
        }

        final content = _projection.canvasSize(map);
        final from = _sourcePoint;
        final currentRoom = from == null ? null : map.roomAt(from);
        final hasRoute = !_route.isEmpty;
        final safeBottom = MediaQuery.paddingOf(context).bottom;

        final fabBottom = _navigating
            ? 112 + safeBottom
            : hasRoute
            ? _viewport.height * _sheetExtent + 12
            : 92 + safeBottom;
        final showFab = !(hasRoute && !_navigating && _sheetExtent > 0.5);

        return Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: GColors.land,
                child: InteractiveViewer(
                  transformationController: _controller,
                  constrained: false,
                  minScale: 0.3,
                  maxScale: 6,
                  boundaryMargin: const EdgeInsets.all(600),
                  onInteractionStart: (_) {
                    _camera.stop();
                    if (_follow) setState(() => _follow = false);
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) =>
                        _setUser(_projection.toMetres(d.localPosition)),
                    child: CustomPaint(
                      size: content,
                      painter: MapPainter(
                        map: map,
                        projection: _projection,
                        user: _user,
                        heading: _heading,
                        route: _route.points,
                        highlightedRoomId: currentRoom?.id,
                        showBeacons: _showBeacons,
                        showStartMarker: _sourceId != null,
                        navigating: _navigating,
                        accuracyInMetres: _live ? _fix.accuracy : 0,
                        ranges: _live && _showBeacons
                            ? [
                                for (final f in _fix.used)
                                  (f.beacon.position, f.distance),
                              ]
                            : const [],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Top chrome.
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_navigating)
                      _NavBanner(
                        route: _route,
                        arrived: _arrived,
                        destination: _labelFor(_destinationId),
                      )
                    else if (_destinationId != null)
                      _DirectionsHeader(
                        sourceLabel: _sourceId != null
                            ? _labelFor(_sourceId)
                            : _user != null
                            ? (_live ? 'Your location' : 'Your location · ${currentRoom?.name ?? ''}')
                            : null,
                        sourceIsYou: _sourceId == null && _user != null,
                        destinationLabel: _labelFor(_destinationId),
                        eta: hasRoute ? _eta(_route.lengthInMetres) : null,
                        onBack: _closeDirections,
                        onSwap: _swap,
                        onPickSource: () async {
                          final id = await _pickPlace(
                            map,
                            'Choose start',
                            includeYou: _user != null,
                          );
                          if (id != null) _setSource(id);
                        },
                        onPickDestination: () async {
                          final id = await _pickPlace(map, 'Choose destination');
                          if (id != null) _setDestination(id);
                        },
                      )
                    else ...[
                      _SearchBar(
                        onTap: () async {
                          final id = await _pickPlace(map, 'Where to?');
                          if (id != null) _setDestination(id);
                        },
                        live: _live,
                      ),
                      const SizedBox(height: 10),
                      _QuickChips(map: map, onPick: _setDestination),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_live)
                          Flexible(
                            child: _LiveChip(
                              fix: _fix,
                              error: _scanner?.error,
                              conflicts: _engine?.conflicts ?? const [],
                              onTap: () => _showLiveDetails(map),
                            ),
                          ),
                        const Spacer(),
                        if (!_navigating)
                          _RoundButton(
                            icon: Icons.layers_outlined,
                            onTap: () => _showLayers(map),
                            size: 42,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Bottom chrome.
            if (_navigating)
              Align(
                alignment: Alignment.bottomCenter,
                child: _NavBottomBar(
                  route: _route,
                  arrived: _arrived,
                  destination: _labelFor(_destinationId),
                  onExit: _exitNavigation,
                  onOverview: _overview,
                ),
              )
            else if (hasRoute)
              NotificationListener<DraggableScrollableNotification>(
                onNotification: (n) {
                  setState(() => _sheetExtent = n.extent);
                  return false;
                },
                child: _RoutePreviewSheet(
                  controller: _sheet,
                  route: _route,
                  via: _via(map),
                  onStart: _startNavigation,
                  onSteps: () => _sheet.animateTo(
                    0.8,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  ),
                ),
              )
            else
              Align(
                alignment: Alignment.bottomCenter,
                child: _HintCard(
                  text: _destinationId != null
                      ? 'Choose a starting point, tap the map, or tap ◎ to find yourself.'
                      : _user == null
                      ? 'Tap the map to set your position, or tap ◎ to locate with beacons.'
                      : 'Where to? Search for a room above.',
                ),
              ),

            if (_navigating && !_follow)
              Positioned(
                left: 16,
                bottom: fabBottom,
                child: _RecenterPill(
                  onTap: () {
                    setState(() => _follow = true);
                    _lastFollowed = null;
                    _followUser();
                  },
                ),
              ),

            if (showFab)
              Positioned(
                right: 16,
                bottom: fabBottom,
                child: _RoundButton(
                  icon: _live
                      ? (_follow ? Icons.my_location : Icons.location_searching)
                      : Icons.location_disabled_outlined,
                  iconColor: _live && _follow ? GColors.blue : GColors.textMuted,
                  onTap: _onMyLocation,
                  size: 54,
                ),
              ),
          ],
        );
      },
    );
  }

  String _via(MapData map) {
    final pts = _route.points;
    final start = map.roomAt(pts.first)?.id;
    final end = map.roomAt(pts.last)?.id;
    final names = <String>[];
    for (var i = 1; i < pts.length; i++) {
      final room = map.roomAt((pts[i - 1] + pts[i]) / 2);
      if (room == null || room.id == start || room.id == end) continue;
      if (!names.contains(room.name)) names.add(room.name);
    }
    return names.isEmpty ? 'Direct route' : 'via ${names.join(', ')}';
  }

  // --- sheets --------------------------------------------------------------

  Future<String?> _pickPlace(
    MapData map,
    String title, {
    bool includeYou = false,
  }) {
    final user = _user;
    final nav = _navigator;

    String? distanceTo(Offset target) {
      if (user == null || nav == null) return null;
      final r = nav.route(user, target);
      return r.isEmpty ? null : '${r.lengthInMetres.toStringAsFixed(0)} m';
    }

    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: GColors.text,
                ),
              ),
            ),
            if (includeYou)
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFE8F0FE),
                  child: Icon(Icons.my_location, color: GColors.blue, size: 20),
                ),
                title: const Text(
                  'Your location',
                  style: TextStyle(color: GColors.blue),
                ),
                onTap: () => Navigator.pop(context, _you),
              ),
            for (final e in map.exits)
              _PlaceTile(
                icon: Icons.door_front_door,
                color: GColors.green,
                title: e.name,
                subtitle: 'Entrance · ${_labelFor(e.room)}',
                distance: distanceTo(_anchor(e.id) ?? e.position),
                onTap: () => Navigator.pop(context, e.id),
              ),
            for (final r in map.rooms)
              _PlaceTile(
                icon: RoomStyle.of(r.id).icon,
                color: RoomStyle.of(r.id).accent,
                title: r.name,
                subtitle:
                    'Room · ${(r.bounds.width * r.bounds.height).toStringAsFixed(1)} m²',
                distance: distanceTo(r.center),
                onTap: () => Navigator.pop(context, r.id),
              ),
          ],
        ),
      ),
    );
  }

  void _showLayers(MapData map) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Map details',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.sensors),
                title: const Text('Live location (BLE beacons)'),
                value: _live,
                onChanged: (_) async {
                  await _toggleLive();
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.bluetooth),
                title: const Text('Show beacons & ranges'),
                value: _showBeacons,
                onChanged: (v) {
                  setState(() => _showBeacons = v);
                  setSheet(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.fit_screen),
                title: const Text('Show whole home'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _overview();
                },
              ),
              ListTile(
                leading: const Icon(Icons.radar),
                title: const Text('BLE scanner'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => BleDebugScreen(map: map)),
                  );
                },
              ),
              if (widget.onSignOut != null)
                ListTile(
                  leading: const Icon(Icons.logout_rounded, color: GColors.redDark),
                  title: const Text('Sign out', style: TextStyle(color: GColors.redDark)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    widget.onSignOut!();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLiveDetails(MapData map) {
    final conflicts = _engine?.conflicts ?? const <String>[];
    final error = _scanner?.error;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          children: [
            Text(
              _fix.label,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              _fix.point == null
                  ? 'Waiting for beacons…'
                  : '±${_fix.accuracy.toStringAsFixed(1)} m · ${_labelFor(_fix.roomId)}',
              style: const TextStyle(color: GColors.textMuted),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error, style: const TextStyle(color: GColors.redDark)),
            ],
            if (conflicts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Two or more radios are advertising as ${conflicts.join(', ')}. '
                'Give each transmitter a different minor.',
                style: const TextStyle(color: GColors.redDark),
              ),
            ],
            const SizedBox(height: 12),
            for (final f in _fix.used)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.bluetooth, color: Color(0xFF00897B)),
                title: Text('${f.beacon.id} · ${_labelFor(f.beacon.room)}'),
                subtitle: Text(
                  '${f.rssi.toStringAsFixed(0)} dBm · ≈${f.distance.toStringAsFixed(1)} m',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --- helpers ---------------------------------------------------------------

String _eta(double metres) {
  final seconds = (metres / _walkingSpeed).ceil();
  if (seconds < 60) return '$seconds sec';
  return '${(seconds / 60).ceil()} min';
}

String _distance(double metres) => metres < 10
    ? '${metres.toStringAsFixed(1)} m'
    : '${metres.toStringAsFixed(0)} m';

IconData _maneuverIcon(Maneuver m) => switch (m) {
  Maneuver.depart => Icons.navigation,
  Maneuver.straight => Icons.straight,
  Maneuver.left => Icons.turn_left,
  Maneuver.right => Icons.turn_right,
  Maneuver.sharpLeft => Icons.turn_sharp_left,
  Maneuver.sharpRight => Icons.turn_sharp_right,
  Maneuver.uTurn => Icons.u_turn_left,
  Maneuver.arrive => Icons.flag,
};

// --- browse mode -----------------------------------------------------------

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap, required this.live});

  final VoidCallback onTap;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shadowColor: Colors.black38,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 16),
              const Icon(Icons.location_on, color: GColors.red),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Search here',
                  style: TextStyle(fontSize: 16, color: GColors.textMuted),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: live ? GColors.blue : const Color(0xFFE8EAED),
                  child: Icon(
                    Icons.home,
                    size: 18,
                    color: live ? Colors.white : GColors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickChips extends StatelessWidget {
  const _QuickChips({required this.map, required this.onPick});

  final MapData map;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final chips = [
      for (final e in map.exits)
        (e.id, e.name.split(' (').first, Icons.door_front_door, GColors.green),
      for (final r in map.rooms)
        if (!RoomStyle.of(r.id).walkway)
          (r.id, r.name, RoomStyle.of(r.id).icon, RoomStyle.of(r.id).accent),
    ];

    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (id, label, icon, color) = chips[i];
          return Material(
            color: Colors.white,
            elevation: 2,
            shadowColor: Colors.black26,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => onPick(id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: GColors.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 84, 12),
        child: Material(
          color: Colors.white,
          elevation: 3,
          shadowColor: Colors.black38,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.touch_app_outlined, color: GColors.blue, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(fontSize: 13, color: GColors.text),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.distance,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? distance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color,
        child: Icon(icon, color: Colors.white, size: 20),
      ),
      title: Text(title, style: const TextStyle(color: GColors.text)),
      subtitle: Text(subtitle),
      trailing: distance == null
          ? null
          : Text(distance!, style: const TextStyle(color: GColors.textMuted)),
      onTap: onTap,
    );
  }
}

// --- directions preview ----------------------------------------------------

class _DirectionsHeader extends StatelessWidget {
  const _DirectionsHeader({
    required this.sourceLabel,
    required this.sourceIsYou,
    required this.destinationLabel,
    required this.eta,
    required this.onBack,
    required this.onSwap,
    required this.onPickSource,
    required this.onPickDestination,
  });

  final String? sourceLabel;
  final bool sourceIsYou;
  final String destinationLabel;
  final String? eta;
  final VoidCallback onBack;
  final VoidCallback onSwap;
  final VoidCallback onPickSource;
  final VoidCallback onPickDestination;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back, color: GColors.text),
                ),
                Column(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: sourceIsYou ? GColors.blue : Colors.white,
                        border: Border.all(
                          color: sourceIsYou ? Colors.white : GColors.text,
                          width: sourceIsYou ? 2.5 : 2,
                        ),
                        boxShadow: sourceIsYou
                            ? const [
                                BoxShadow(color: Colors.black26, blurRadius: 2),
                              ]
                            : null,
                      ),
                    ),
                    for (var i = 0; i < 3; i++)
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 2.5),
                        width: 3,
                        height: 3,
                        decoration: const BoxDecoration(
                          color: GColors.wall,
                          shape: BoxShape.circle,
                        ),
                      ),
                    const Icon(Icons.location_on, color: GColors.red, size: 18),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      _Field(
                        text: sourceLabel ?? 'Choose starting point',
                        color: sourceLabel == null
                            ? GColors.textMuted
                            : sourceIsYou
                            ? GColors.blue
                            : GColors.text,
                        onTap: onPickSource,
                      ),
                      const SizedBox(height: 8),
                      _Field(
                        text: destinationLabel,
                        color: GColors.text,
                        onTap: onPickDestination,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onSwap,
                  icon: const Icon(Icons.swap_vert, color: GColors.text),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD2E3FC),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.directions_walk,
                          size: 18,
                          color: Color(0xFF174EA6),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          eta ?? '—',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF174EA6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.text, required this.color, required this.onTap});

  final String text;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: GColors.land,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          height: 40,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15, color: color),
          ),
        ),
      ),
    );
  }
}

class _RoutePreviewSheet extends StatelessWidget {
  const _RoutePreviewSheet({
    required this.controller,
    required this.route,
    required this.via,
    required this.onStart,
    required this.onSteps,
  });

  final DraggableScrollableController controller;
  final NavRoute route;
  final String via;
  final VoidCallback onStart;
  final VoidCallback onSteps;

  @override
  Widget build(BuildContext context) {
    final legs = route.instructions;

    return DraggableScrollableSheet(
      controller: controller,
      initialChildSize: 0.3,
      minChildSize: 0.2,
      maxChildSize: 0.85,
      snap: true,
      snapSizes: const [0.3],
      builder: (context, scroll) => Material(
        color: Colors.white,
        elevation: 12,
        shadowColor: Colors.black54,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: ListView(
          controller: scroll,
          padding: EdgeInsets.zero,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8, bottom: 12),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: GColors.wall,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: _eta(route.lengthInMetres),
                          style: const TextStyle(
                            color: GColors.green,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text: '  (${_distance(route.lengthInMetres)})',
                          style: const TextStyle(
                            color: GColors.textMuted,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Best route · $via',
                    style: const TextStyle(color: GColors.textMuted, fontSize: 14),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: GColors.blue,
                          minimumSize: const Size(0, 44),
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                        onPressed: onStart,
                        icon: const Icon(Icons.navigation, size: 18),
                        label: const Text('Start'),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: GColors.blue,
                          shape: const StadiumBorder(),
                          side: const BorderSide(color: GColors.wall),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                        ),
                        onPressed: onSteps,
                        icon: const Icon(Icons.format_list_bulleted, size: 18),
                        label: const Text('Steps'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            for (final step in legs)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 20, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 40,
                      child: Icon(
                        _maneuverIcon(step.maneuver),
                        color: step.maneuver == Maneuver.arrive
                            ? GColors.red
                            : GColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            step.detail.isEmpty
                                ? step.title
                                : '${step.title} ${step.maneuver == Maneuver.arrive ? '' : step.detail}'
                                      .trim(),
                            style: const TextStyle(
                              fontSize: 15,
                              color: GColors.text,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              if (step.distance > 0)
                                Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: Text(
                                    _distance(step.distance),
                                    style: const TextStyle(
                                      color: GColors.textMuted,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              const Expanded(child: Divider(height: 1)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// --- turn-by-turn ----------------------------------------------------------

class _NavBanner extends StatelessWidget {
  const _NavBanner({
    required this.route,
    required this.arrived,
    required this.destination,
  });

  final NavRoute route;
  final bool arrived;
  final String destination;

  @override
  Widget build(BuildContext context) {
    final legs = route.instructions;

    IconData icon;
    String title;
    String detail;
    String distance = '';
    NavStep? then;

    if (route.isEmpty && !arrived) {
      icon = Icons.gps_not_fixed;
      title = 'Finding your position…';
      detail = 'Walk into a room on the map';
    } else if (arrived || legs.length <= 1) {
      icon = Icons.flag;
      title = 'You have arrived';
      detail = destination;
    } else {
      final next = legs[1];
      icon = _maneuverIcon(next.maneuver);
      title = next.title;
      detail = next.maneuver == Maneuver.arrive ? '' : next.detail;
      distance = _distance(legs[0].distance);
      then = legs.length > 2 ? legs[2] : null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: GColors.navGreen,
          elevation: 4,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomRight: const Radius.circular(16),
            bottomLeft: Radius.circular(then == null ? 16 : 0),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Row(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: Colors.white, size: 44),
                    if (distance.isNotEmpty)
                      Text(
                        distance,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      if (detail.isNotEmpty)
                        Text(
                          detail,
                          style: const TextStyle(
                            color: Color(0xDDFFFFFF),
                            fontSize: 17,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (then != null)
          Material(
            color: GColors.navGreenDark,
            elevation: 4,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Then',
                    style: TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  const SizedBox(width: 6),
                  Icon(_maneuverIcon(then.maneuver), color: Colors.white, size: 20),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _NavBottomBar extends StatelessWidget {
  const _NavBottomBar({
    required this.route,
    required this.arrived,
    required this.destination,
    required this.onExit,
    required this.onOverview,
  });

  final NavRoute route;
  final bool arrived;
  final String destination;
  final VoidCallback onExit;
  final VoidCallback onOverview;

  @override
  Widget build(BuildContext context) {
    final metres = route.lengthInMetres;
    final seconds = (metres / _walkingSpeed).ceil();
    final arrival = TimeOfDay.fromDateTime(
      DateTime.now().add(Duration(seconds: seconds)),
    ).format(context);

    return Material(
      color: Colors.white,
      elevation: 16,
      shadowColor: Colors.black54,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              _CircleAction(icon: Icons.close, onTap: onExit),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      arrived ? 'Arrived' : _eta(metres),
                      style: const TextStyle(
                        color: GColors.green,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      arrived
                          ? destination
                          : '${_distance(metres)} · $arrival',
                      style: const TextStyle(
                        color: GColors.textMuted,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
              if (arrived)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: GColors.blue,
                    minimumSize: const Size(0, 44),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: onExit,
                  child: const Text('Done'),
                )
              else
                _CircleAction(icon: Icons.alt_route, onTap: onOverview),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecenterPill extends StatelessWidget {
  const _RecenterPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black38,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.navigation, color: GColors.blue, size: 20),
              SizedBox(width: 8),
              Text(
                'Re-centre',
                style: TextStyle(
                  color: GColors.blue,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- shared pieces ---------------------------------------------------------

class _LiveChip extends StatelessWidget {
  const _LiveChip({
    required this.fix,
    required this.error,
    required this.conflicts,
    required this.onTap,
  });

  final PositionFix fix;
  final String? error;
  final List<String> conflicts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final problem = error != null || conflicts.isNotEmpty;
    final dot = problem
        ? GColors.red
        : switch (fix.method) {
            FixMethod.none => const Color(0xFFF9AB00),
            FixMethod.trilateration => GColors.green,
            _ => GColors.blue,
          };
    final label = error != null
        ? 'Bluetooth problem'
        : conflicts.isNotEmpty
        ? 'Duplicate beacon ids'
        : fix.point == null
        ? 'Searching for beacons…'
        : '${fix.label} · ±${fix.accuracy.toStringAsFixed(1)} m';

    return Material(
      color: Colors.white,
      elevation: 2,
      shadowColor: Colors.black26,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: GColors.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onTap,
    this.size = 48,
    this.iconColor = GColors.textMuted,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black38,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: iconColor, size: size * 0.46),
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(side: BorderSide(color: GColors.wall)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(icon, color: GColors.text),
        ),
      ),
    );
  }
}
