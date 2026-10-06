import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../live/live_location_client.dart';
import '../live/people_painter.dart';
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
  static const _topChrome = 108.0;

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
                      foregroundPainter: PeoplePainter(
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                      const SizedBox(height: 8),
                      const _AssistLegend(),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: ListenableBuilder(
                      listenable: widget.client,
                      builder: (context, _) => _EmergencyButton(
                        active: widget.client.emergency,
                        enabled:
                            widget.client.state == LiveConnection.connected,
                        onPressed: _confirmEmergency,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmEmergency() async {
    final ending = widget.client.emergency;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          ending ? Icons.check_circle_outline : Icons.warning_amber_rounded,
          color: ending ? GColors.green : GColors.red,
          size: 40,
        ),
        title: Text(ending ? 'End the emergency?' : 'Declare an emergency?'),
        content: Text(
          ending ? 'Employees will return to the normal map.' : 'Every employee\'s app will immediately be alerted and can navigate to the nearest safe exit. Employees can also volunteer as emergency responders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: ending ? GColors.green : GColors.red,
            ),
            child: Text(ending ? 'All clear' : 'Declare emergency'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!widget.client.setEmergency(!ending)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not connected to the server. Try again.'),
        ),
      );
    }
  }
}

class _EmergencyButton extends StatelessWidget {
  const _EmergencyButton({
    required this.active,
    required this.enabled,
    required this.onPressed,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: active ? GColors.green : GColors.red,
          minimumSize: const Size(0, 56),
          elevation: 6,
          shape: const StadiumBorder(),
        ),
        onPressed: enabled ? onPressed : null,
        icon: Icon(
          active ? Icons.check_circle_outline : Icons.warning_amber_rounded,
        ),
        label: Text(
          active ? 'Emergency active · tap for all clear' : 'EMERGENCY',
        ),
      ),
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
      heightFactor: 1,
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

class _AssistLegend extends StatelessWidget {
  const _AssistLegend();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: const StadiumBorder(),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LegendItem(
              color: GColors.assist,
              icon: Icons.accessible_rounded,
              label: 'Needs assistance',
            ),
            SizedBox(width: 14),
            _LegendItem(
              color: GColors.responder,
              icon: Icons.health_and_safety_rounded,
              label: 'Responder',
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.color,
    required this.icon,
    required this.label,
  });

  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, size: 14, color: Colors.white),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: GColors.text,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

