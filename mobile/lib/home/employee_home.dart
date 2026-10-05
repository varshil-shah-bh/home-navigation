import 'package:flutter/material.dart';

import '../background/background_service.dart';
import '../background/emergency_alerter.dart';
import '../call/call_controller.dart';
import '../call/call_overlay.dart';
import '../live/live_location_client.dart';
import '../map/map_view.dart';

/// Employee home: the navigation map, which streams this user's position to admins
/// and rings when an admin calls.
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
  late final CallController _call = CallController(client: _client);
  late final EmergencyAlerter _alerter;

  @override
  void initState() {
    super.initState();
    _alerter = EmergencyAlerter(_client);
    BackgroundService.start();
  }

  @override
  void dispose() {
    _alerter.dispose();
    BackgroundService.stop();
    _call.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallHost(
      controller: _call,
      child: Scaffold(
        body: ListenableBuilder(
          listenable: _client,
          builder: (context, _) => MapView(
            onSignOut: widget.onSignOut,
            onLocation: _client.sendLocation,
            emergency: _client.emergency,
          ),
        ),
      ),
    );
  }
}
