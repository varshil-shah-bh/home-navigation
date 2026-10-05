import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../live/live_location_client.dart';
import '../map/map_data.dart';
import '../map/map_painter.dart';

/// Admin view: the home layout with every connected employee plotted live.
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({
    super.key,
    required this.client,
    this.assetPath = 'assets/home_map.json',
    this.onSignOut,
  });

  final LiveLocationClient client;
  final String assetPath;
  final VoidCallback? onSignOut;

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  static const _projection = MapProjection(scale: 70, mapOrigin: Offset.zero);
  static const _topChrome = 72.0;

  final _controller = TransformationController();
  MapData? _map;
  Object? _error;
  bool _didFit = false;
  Timer? _ageTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Re-evaluates which markers are stale.
    _ageTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ageTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final map = await MapData.load(widget.assetPath);
      if (mounted) setState(() => _map = map);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Matrix4 _fitMatrix(MapData map, Size viewport) {
    final content = _projection.canvasSize(map);
    final usable = math.max(160.0, viewport.height - _topChrome - 16);
    final s = math
        .min(viewport.width / content.width, usable / content.height)
        .clamp(0.2, 2.0);
    final dx = (viewport.width - content.width * s) / 2;
    final dy = _topChrome + (usable - content.height * s) / 2;
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

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
        if (!_didFit) {
          _didFit = true;
          final viewport = constraints.biggest;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _controller.value = _fitMatrix(map, viewport);
          });
        }

        return ColoredBox(
          color: GColors.land,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _controller,
                  constrained: false,
                  minScale: 0.3,
                  maxScale: 6,
                  boundaryMargin: const EdgeInsets.all(600),
                  child: ListenableBuilder(
                    listenable: widget.client,
                    builder: (context, _) => CustomPaint(
                      size: _projection.canvasSize(map),
                      painter: MapPainter(map: map, projection: _projection),
                      foregroundPainter: _PeoplePainter(
                        users: widget.client.users,
                        projection: _projection,
                        now: DateTime.now(),
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: ListenableBuilder(
                          listenable: widget.client,
                          builder: (context, _) => _StatusChip(
                            state: widget.client.state,
                            online: widget.client.users.length,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: Colors.white,
                        elevation: 3,
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Fit to screen',
                          icon: const Icon(Icons.fit_screen),
                          onPressed: () => _controller.value = _fitMatrix(
                            map,
                            constraints.biggest,
                          ),
                        ),
                      ),
                      if (widget.onSignOut != null) ...[
                        const SizedBox(width: 8),
                        Material(
                          color: Colors.white,
                          elevation: 3,
                          shape: const CircleBorder(),
                          child: IconButton(
                            tooltip: 'Sign out',
                            icon: const Icon(
                              Icons.logout_rounded,
                              color: GColors.redDark,
                            ),
                            onPressed: widget.onSignOut,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state, required this.online});

  final LiveConnection state;
  final int online;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      LiveConnection.connected => (
        GColors.green,
        online == 1 ? '1 employee online' : '$online employees online',
      ),
      LiveConnection.connecting => (Colors.orange, 'Connecting…'),
      LiveConnection.disconnected => (GColors.red, 'Disconnected · retrying'),
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.white,
        elevation: 3,
        shape: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GColors.text,
                    fontWeight: FontWeight.w600,
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

class _PeoplePainter extends CustomPainter {
  _PeoplePainter({
    required this.users,
    required this.projection,
    required this.now,
  });

  static const _staleAfter = Duration(seconds: 30);
  static const _palette = [
    Color(0xFF1A73E8),
    Color(0xFFE37400),
    Color(0xFF8E63CE),
    Color(0xFF188038),
    Color(0xFFD93025),
    Color(0xFF00897B),
  ];

  final List<LiveUser> users;
  final MapProjection projection;
  final DateTime now;

  @override
  void paint(Canvas canvas, Size size) {
    for (final user in users) {
      final stale = now.difference(user.seenAt) > _staleAfter;
      final base = _palette[user.userId.hashCode.abs() % _palette.length];
      final color = stale ? base.withValues(alpha: 0.45) : base;
      final c = projection.toPixels(user.position);

      canvas.drawCircle(c + const Offset(0, 1.5), 15, Paint()..color = const Color(0x33000000));
      canvas.drawCircle(c, 15, Paint()..color = Colors.white);
      canvas.drawCircle(c, 12, Paint()..color = color);
      _text(
        canvas,
        user.name.isEmpty ? '?' : user.name.characters.first.toUpperCase(),
        c,
        const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
      );

      final label = _layout(
        user.name,
        TextStyle(
          color: stale ? GColors.textMuted : GColors.text,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      );
      final pill = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: c + Offset(0, 15 + 4 + label.height / 2 + 2),
          width: label.width + 12,
          height: label.height + 4,
        ),
        const Radius.circular(10),
      );
      canvas.drawRRect(pill, Paint()..color = const Color(0xE6FFFFFF));
      label.paint(canvas, pill.center - Offset(label.width / 2, label.height / 2));
    }
  }

  TextPainter _layout(String text, TextStyle style) =>
      TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 140);

  void _text(Canvas canvas, String text, Offset centre, TextStyle style) {
    final tp = _layout(text, style);
    tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_PeoplePainter old) => true;
}
