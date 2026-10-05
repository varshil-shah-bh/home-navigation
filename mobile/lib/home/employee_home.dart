import 'package:flutter/material.dart';

import '../live/live_location_client.dart';
import '../map/map_view.dart';

/// Employee home: the navigation map, which also streams this user's position to admins.
class EmployeeHome extends StatefulWidget {
  const EmployeeHome({super.key, required this.token, required this.onSignOut});

  final String token;
  final VoidCallback onSignOut;

  @override
  State<EmployeeHome> createState() => _EmployeeHomeState();
}

class _EmployeeHomeState extends State<EmployeeHome> {
  late final LiveLocationClient _client = LiveLocationClient(token: widget.token)
    ..connect();

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: MapView(
        onSignOut: widget.onSignOut,
        onLocation: _client.sendLocation,
      ),
    );
  }
}
