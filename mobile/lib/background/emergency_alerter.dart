import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:vibration/vibration.dart';

import '../live/live_location_client.dart';
import 'background_service.dart';

/// Vibrates and sounds a siren while an admin emergency is active, including when the app is in the background.
class EmergencyAlerter with WidgetsBindingObserver {
  EmergencyAlerter(this._client) {
    WidgetsBinding.instance.addObserver(this);
    _client.addListener(_onChange);
    _onChange();
  }

  /// Pause, buzz, pause, buzz; index 0 is where a repeating pattern loops back to.
  static const _pattern = [0, 700, 350, 700, 350];

  final LiveLocationClient _client;
  final AudioPlayer _player = AudioPlayer();
  bool _active = false;

  void _onChange() {
    final emergency = _client.emergency;
    if (emergency == _active) return;
    _active = emergency;
    if (emergency) {
      BackgroundService.showEmergency(_client.emergencyBy);
      _vibrate();
      _startSiren();
    } else {
      BackgroundService.clearEmergency();
      Vibration.cancel();
      _player.stop();
    }
  }

  Future<void> _startSiren() async {
    try {
      await _player.setAudioContext(
        AudioContextConfig(focus: AudioContextConfigFocus.gain).build(),
      );
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(BytesSource(_siren, mimeType: 'audio/wav'));
    } catch (e) {
      debugPrint('Emergency siren failed: $e');
    }
  }

  /// One second of a two-tone siren as a 16-bit mono WAV, built in memory so no asset is needed.
  static final Uint8List _siren = () {
    const rate = 22050;
    const samples = rate;
    final data = ByteData(44 + samples * 2);
    void tag(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    data.setUint32(4, 36 + samples * 2, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    data.setUint32(40, samples * 2, Endian.little);
    for (var i = 0; i < samples; i++) {
      final freq = i < samples ~/ 2 ? 960.0 : 720.0;
      final v = math.sin(2 * math.pi * freq * i / rate) * 0.8;
      data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
    }
    return data.buffer.asUint8List();
  }();

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
    _player.dispose();
  }
}
