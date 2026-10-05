import 'package:flutter/material.dart';

import '../live/live_location_client.dart';
import '../map/map_view.dart';
import 'live_map_screen.dart';

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
  final Widget Function(LiveLocationClient client, VoidCallback onSignOut) builder;
}

/// Admin home. Add a screen by appending to [_tabs].
final _tabs = <_AdminTab>[
  _AdminTab(
    label: 'Live map',
    icon: Icons.people_outline,
    selectedIcon: Icons.people,
    builder: (client, onSignOut) =>
        LiveMapScreen(client: client, onSignOut: onSignOut),
  ),
  _AdminTab(
    label: 'Navigate',
    icon: Icons.explore_outlined,
    selectedIcon: Icons.explore,
    builder: (client, onSignOut) => MapView(onSignOut: onSignOut),
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
  int _index = 0;

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [for (final t in _tabs) t.builder(_client, widget.onSignOut)],
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
    );
  }
}
