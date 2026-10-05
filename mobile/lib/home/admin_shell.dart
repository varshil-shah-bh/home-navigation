import 'package:flutter/material.dart';

import '../call/call_controller.dart';
import '../call/call_overlay.dart';
import '../live/live_location_client.dart';
import '../map/map_view.dart';
import 'calls_screen.dart';
import 'live_map_screen.dart';

class _TabContext {
  const _TabContext({
    required this.token,
    required this.client,
    required this.call,
    required this.onSignOut,
  });

  final String token;
  final LiveLocationClient client;
  final CallController call;
  final VoidCallback onSignOut;
}

class _AdminTab {
  const _AdminTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function(_TabContext ctx) builder;
}

/// Admin home. Add a screen by appending to [_tabs].
final _tabs = <_AdminTab>[
  _AdminTab(
    label: 'Live map',
    icon: Icons.people_outline,
    selectedIcon: Icons.people,
    builder: (ctx) => LiveMapScreen(client: ctx.client, onSignOut: ctx.onSignOut),
  ),
  _AdminTab(
    label: 'Calls',
    icon: Icons.call_outlined,
    selectedIcon: Icons.call,
    builder: (ctx) => CallsScreen(
      token: ctx.token,
      client: ctx.client,
      call: ctx.call,
      onSignOut: ctx.onSignOut,
    ),
  ),
  _AdminTab(
    label: 'Navigate',
    icon: Icons.explore_outlined,
    selectedIcon: Icons.explore,
    builder: (ctx) => MapView(onSignOut: ctx.onSignOut),
  ),
];

class AdminShell extends StatefulWidget {
  const AdminShell({super.key, required this.token, required this.onSignOut});

  final String token;
  final VoidCallback onSignOut;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  late final LiveLocationClient _client = LiveLocationClient(token: widget.token)
    ..connect();
  late final CallController _call = CallController(client: _client);
  int _index = 0;

  @override
  void dispose() {
    _call.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _TabContext(
      token: widget.token,
      client: _client,
      call: _call,
      onSignOut: widget.onSignOut,
    );
    return CallHost(
      controller: _call,
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [for (final t in _tabs) t.builder(ctx)],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            for (final t in _tabs)
              NavigationDestination(
                icon: Icon(t.icon),
                selectedIcon: Icon(t.selectedIcon),
                label: t.label,
              ),
          ],
        ),
      ),
    );
  }
}
