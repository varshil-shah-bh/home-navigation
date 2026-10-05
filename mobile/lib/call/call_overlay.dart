import 'dart:async';

import 'package:flutter/material.dart';

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
              : PopScope(canPop: false, child: _CallScreen(controller: widget.controller)),
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
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),
              CircleAvatar(
                radius: 52,
                backgroundColor: const Color(0xFF1A73E8),
                child: Text(
                  name.characters.first.toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                name,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              if (status != null)
                Text(status, style: const TextStyle(color: Colors.white70, fontSize: 16))
              else
                _Elapsed(since: c.connectedAt ?? DateTime.now()),
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
                      color: const Color(0xFF188038),
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
    );
  }
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
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
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
    return Text(text, style: const TextStyle(color: Colors.white70, fontSize: 16));
  }
}
