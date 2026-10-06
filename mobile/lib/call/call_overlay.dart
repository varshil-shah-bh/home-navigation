import 'dart:async';

import 'package:flutter/material.dart';

import '../map/map_painter.dart';
import 'call_controller.dart';

/// Shows the in-call / incoming-call screen above [child] and surfaces call notices.
class CallHost extends StatefulWidget {
  const CallHost({super.key, required this.controller, required this.child});

  final CallController controller;
  final Widget child;

  @override
  State<CallHost> createState() => _CallHostState();
}

class _CallHostState extends State<CallHost> {
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.controller.notices.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => widget.controller.isIdle
              ? const SizedBox.shrink()
              : PopScope(
                  canPop: false,
                  child: _CallScreen(controller: widget.controller),
                ),
        ),
      ],
    );
  }
}

class _CallScreen extends StatelessWidget {
  const _CallScreen({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final name = c.peerName.isEmpty ? 'Unknown' : c.peerName;

    final status = switch (c.phase) {
      CallPhase.ringing => 'Incoming Wi-Fi call',
      CallPhase.calling => 'Calling…',
      CallPhase.connecting => 'Connecting…',
      _ => null,
    };

    return Material(
      color: const Color(0xFF202124),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF174EA6), Color(0xFF202124)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0, 0.75],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              children: [
                const Spacer(flex: 2),
                _Halo(
                  pulsing: status != null,
                  child: CircleAvatar(
                    radius: 56,
                    backgroundColor: Colors.white,
                    child: CircleAvatar(
                      radius: 52,
                      backgroundColor: GColors.blue,
                      child: Text(
                        name.characters.first.toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 44,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: status != null
                      ? Text(
                          status,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                        )
                      : _Elapsed(since: c.connectedAt ?? DateTime.now()),
                ),
                const Spacer(flex: 3),
                if (c.phase == CallPhase.ringing)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _Action(
                        icon: Icons.call_end,
                        color: const Color(0xFFD93025),
                        label: 'Decline',
                        onTap: c.decline,
                      ),
                      _Action(
                        icon: Icons.call,
                        color: GColors.green,
                        label: 'Accept',
                        onTap: c.accept,
                      ),
                    ],
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _Action(
                        icon: c.muted ? Icons.mic_off : Icons.mic,
                        color: c.muted ? Colors.white : Colors.white24,
                        iconColor: c.muted ? Colors.black87 : Colors.white,
                        label: c.muted ? 'Unmute' : 'Mute',
                        onTap: c.toggleMute,
                      ),
                      _Action(
                        icon: Icons.call_end,
                        color: const Color(0xFFD93025),
                        label: 'End',
                        onTap: c.hangUp,
                      ),
                      _Action(
                        icon: c.speaker ? Icons.volume_up : Icons.volume_down,
                        color: c.speaker ? Colors.white : Colors.white24,
                        iconColor: c.speaker ? Colors.black87 : Colors.white,
                        label: 'Speaker',
                        onTap: c.toggleSpeaker,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft rings that ripple outward while a call is still being set up.
class _Halo extends StatefulWidget {
  const _Halo({required this.pulsing, required this.child});

  final bool pulsing;
  final Widget child;

  @override
  State<_Halo> createState() => _HaloState();
}

class _HaloState extends State<_Halo> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 200,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) => CustomPaint(
          painter: _HaloPainter(widget.pulsing ? _anim.value : null),
          child: Center(child: child),
        ),
        child: widget.child,
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter(this.t);

  final double? t;

  @override
  void paint(Canvas canvas, Size size) {
    final t = this.t;
    if (t == null) return;
    final c = size.center(Offset.zero);
    for (var i = 0; i < 2; i++) {
      final p = (t + i * 0.5) % 1;
      canvas.drawCircle(
        c,
        58 + 42 * p,
        Paint()..color = Colors.white.withValues(alpha: 0.25 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) => true;
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final Color color;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 68,
              height: 68,
              child: Icon(icon, color: iconColor, size: 30),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
    );
  }
}

class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since});

  final DateTime since;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.since);
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final text = d.inHours > 0 ? '${d.inHours}:$mm:$ss' : '$mm:$ss';
    return Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 15),
    );
  }
}
