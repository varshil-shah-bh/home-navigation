import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../auth/auth_api.dart';

enum LiveConnection { connecting, connected, disconnected }

class LiveUser {
  const LiveUser({
    required this.userId,
    required this.name,
    required this.position,
    required this.seenAt,
  });

  final String userId;
  final String name;

  /// Metres in map space.
  final Offset position;

  /// Local receipt time, so staleness doesn't depend on the server clock.
  final DateTime seenAt;
}

/// WebSocket client for live locations. Employees call [sendLocation]; admins read [users].
class LiveLocationClient extends ChangeNotifier {
  LiveLocationClient({required this.token, Uri? endpoint})
    : _endpoint = endpoint ?? _defaultEndpoint();

  static const _minSendInterval = Duration(milliseconds: 250);
  static const _maxBackoffSeconds = 30;

  final String token;
  final Uri _endpoint;

  final Map<String, LiveUser> _users = {};
  WebSocket? _socket;
  Timer? _retryTimer;
  Timer? _flushTimer;
  int _attempt = 0;
  bool _closed = false;
  LiveConnection _state = LiveConnection.disconnected;

  Offset? _pending;
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  LiveConnection get state => _state;
  List<LiveUser> get users => _users.values.toList();

  static Uri _defaultEndpoint() {
    final base = Uri.parse(apiBaseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws',
    );
  }

  void connect() {
    if (_closed || _socket != null || _state == LiveConnection.connecting) return;
    _open();
  }

  Future<void> _open() async {
    _setState(LiveConnection.connecting);
    try {
      final socket = await WebSocket.connect(
        _endpoint.toString(),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (_closed) {
        await socket.close();
        return;
      }
      socket.pingInterval = const Duration(seconds: 20);
      _socket = socket;
      _attempt = 0;
      _setState(LiveConnection.connected);
      socket.listen(
        _onData,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: true,
      );
      if (_pending != null) _flushNow();
    } catch (_) {
      _onDisconnected();
    }
  }

  void _onDisconnected() {
    _socket = null;
    if (_closed) return;
    _setState(LiveConnection.disconnected);
    _retryTimer?.cancel();
    final seconds = math.min(1 << _attempt, _maxBackoffSeconds);
    if (_attempt < 5) _attempt++;
    _retryTimer = Timer(Duration(seconds: seconds), connect);
  }

  /// Latest position wins; updates are rate-limited and resent after a reconnect.
  void sendLocation(Offset metres) {
    _pending = metres;
    if (_flushTimer != null) return;
    final wait = _minSendInterval - DateTime.now().difference(_lastSentAt);
    if (wait <= Duration.zero) {
      _flushNow();
    } else {
      _flushTimer = Timer(wait, _flushNow);
    }
  }

  void _flushNow() {
    _flushTimer = null;
    final point = _pending, socket = _socket;
    if (point == null || socket == null) return;
    _lastSentAt = DateTime.now();
    socket.add(jsonEncode({'type': 'location', 'x': point.dx, 'y': point.dy}));
  }

  void _onData(Object? data) {
    if (data is! String) return;
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      switch (json['type']) {
        case 'snapshot':
          _users
            ..clear()
            ..addEntries([
              for (final u in json['users'] as List<dynamic>)
                _entry(u as Map<String, dynamic>),
            ]);
        case 'location':
          final entry = _entry(json);
          _users[entry.key] = entry.value;
        case 'offline':
          _users.remove(json['userId'] as String);
        default:
          return;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[live] bad message: $e');
    }
  }

  MapEntry<String, LiveUser> _entry(Map<String, dynamic> json) {
    final id = json['userId'] as String;
    return MapEntry(
      id,
      LiveUser(
        userId: id,
        name: json['name'] as String,
        position: Offset(
          (json['x'] as num).toDouble(),
          (json['y'] as num).toDouble(),
        ),
        seenAt: DateTime.now(),
      ),
    );
  }

  void _setState(LiveConnection next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _retryTimer?.cancel();
    _flushTimer?.cancel();
    _socket?.close();
    super.dispose();
  }
}
