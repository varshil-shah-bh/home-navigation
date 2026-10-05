import 'package:flutter/widgets.dart';
import 'package:vibration/vibration.dart';

import '../live/live_location_client.dart';
import 'background_service.dart';

/// Vibrates while an admin emergency is active, including when the app is in the background.
class EmergencyAlerter with WidgetsBindingObserver {
  EmergencyAlerter(this._client) {
    WidgetsBinding.instance.addObserver(this);
    _client.addListener(_onChange);
    _onChange();
  }

  /// Pause, buzz, pause, buzz; index 0 is where a repeating pattern loops back to.
  static const _pattern = [0, 700, 350, 700, 350];

  final LiveLocationClient _client;
  bool _active = false;

  void _onChange() {
    final emergency = _client.emergency;
    if (emergency == _active) return;
    _active = emergency;
    if (emergency) {
      BackgroundService.showEmergency(_client.emergencyBy);
      _vibrate();
    } else {
      BackgroundService.clearEmergency();
      Vibration.cancel();
    }
  }

  void _vibrate() {
    final inForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    // Looking at the screen already: a short burst. Otherwise buzz until the app is opened.
    Vibration.vibrate(pattern: _pattern, repeat: inForeground ? -1 : 0);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _active) Vibration.cancel();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _client.removeListener(_onChange);
    Vibration.cancel();
  }
}
