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
    this.hasDisability = false,
    this.isResponder = false,
  });

  final String userId;
  final String name;
  final bool hasDisability;

  /// Volunteering on the emergency response team.
  final bool isResponder;

  /// Metres in map space.
  final Offset position;

  /// Local receipt time, so staleness doesn't depend on the server clock.
  final DateTime seenAt;

  LiveUser withResponder(bool value) => LiveUser(
    userId: userId,
    name: name,
    position: position,
    seenAt: seenAt,
    hasDisability: hasDisability,
    isResponder: value,
  );
}

/// A call-signalling message relayed by the server (WebRTC offer/answer/ICE, etc.).
class CallSignal {
  const CallSignal({
    required this.from,
    required this.fromName,
    required this.fromRole,
    required this.callId,
    required this.kind,
    this.data,
  });

  final String from;
  final String fromName;
  final String fromRole;
  final String callId;

  /// offer, answer, candidate, reject, hangup, or unavailable (server-generated).
  final String kind;
  final Map<String, dynamic>? data;
}

/// WebSocket client for live locations, presence and call signalling.
/// Employees call [sendLocation]; admins read [users] and [isOnline].
class LiveLocationClient extends ChangeNotifier {
  LiveLocationClient({required this.token, Uri? endpoint})
    : _endpoint = endpoint ?? _defaultEndpoint();

  static const _minSendInterval = Duration(milliseconds: 250);
  static const _maxBackoffSeconds = 30;

  final String token;
  final Uri _endpoint;

  final Map<String, LiveUser> _users = {};
  final Map<String, String> _online = {};
  final _signals = StreamController<CallSignal>.broadcast();
  WebSocket? _socket;
  Timer? _retryTimer;
  Timer? _flushTimer;
  int _attempt = 0;
  bool _closed = false;
  LiveConnection _state = LiveConnection.disconnected;
  bool _emergency = false;
  String? _emergencyBy;
  bool _responding = false;
  final Set<String> _responders = {};

  Offset? _pending;
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  LiveConnection get state => _state;
  List<LiveUser> get users => [
    for (final u in _users.values)
      if (_responders.contains(u.userId)) u.withResponder(true) else u,
  ];

  Stream<CallSignal> get signals => _signals.stream;

  /// Whether an admin has raised an emergency, as last reported by the server.
  bool get emergency => _emergency;
  String? get emergencyBy => _emergencyBy;

  /// Whether this user has joined the emergency response team. While true, [users]
  /// holds every other employee's live location.
  bool get responding => _responding;

  /// Only meaningful for admins, and only while connected.
  bool isOnline(String userId) =>
      _state == LiveConnection.connected && _online.containsKey(userId);

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
    _online.clear();
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
          _online
            ..clear()
            ..addEntries([
              for (final u in (json['online'] as List<dynamic>? ?? const []))
                MapEntry(
                  (u as Map<String, dynamic>)['userId'] as String,
                  u['name'] as String,
                ),
            ]);
          _responders
            ..clear()
            ..addAll([
              for (final r in (json['responders'] as List<dynamic>? ?? const []))
                (r as Map<String, dynamic>)['userId'] as String,
            ]);
        case 'location':
          final entry = _entry(json);
          _users[entry.key] = entry.value;
          _online[entry.key] = entry.value.name;
        case 'emergency':
          _emergency = json['active'] == true;
          _emergencyBy = _emergency ? json['by'] as String? : null;
          if (!_emergency) {
            // Only responders hold other people's locations as an employee; drop them with the team.
            if (_responding) _users.clear();
            _responders.clear();
            _responding = false;
          }
        case 'responder':
          final id = json['userId'] as String;
          if (json['active'] == true) {
            _responders.add(id);
          } else {
            _responders.remove(id);
          }
        case 'responder_status':
          _responding = json['active'] == true;
          if (!_responding) _users.clear();
        case 'online':
          _online[json['userId'] as String] = json['name'] as String;
        case 'offline':
          final id = json['userId'] as String;
          _users.remove(id);
          _online.remove(id);
        case 'signal':
          _signals.add(
            CallSignal(
              from: json['from'] as String,
              fromName: json['fromName'] as String? ?? '',
              fromRole: json['fromRole'] as String? ?? '',
              callId: json['callId'] as String,
              kind: json['kind'] as String,
              data: json['data'] as Map<String, dynamic>?,
            ),
          );
          return;
        default:
          return;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[live] bad message: $e');
    }
  }

  /// Admin only; the server ignores it from anyone else. Returns false if not connected.
  bool setEmergency(bool active) {
    final socket = _socket;
    if (socket == null) return false;
    socket.add(jsonEncode({'type': 'emergency', 'active': active}));
    return true;
  }

  /// Employee only: join or leave the response team. Returns false if not connected.
  bool setResponder(bool active) {
    final socket = _socket;
    if (socket == null) return false;
    socket.add(jsonEncode({'type': 'responder', 'active': active}));
    return true;
  }

  /// Returns false when the server can't be reached right now.
  bool sendSignal({
    required String to,
    required String callId,
    required String kind,
    Map<String, dynamic>? data,
  }) {
    final socket = _socket;
    if (socket == null) return false;
    socket.add(
      jsonEncode({
        'type': 'signal',
        'to': to,
        'callId': callId,
        'kind': kind,
        'data': ?data,
      }),
    );
    return true;
  }

  MapEntry<String, LiveUser> _entry(Map<String, dynamic> json) {
    final id = json['userId'] as String;
    return MapEntry(
      id,
      LiveUser(
        userId: id,
        name: json['name'] as String,
        hasDisability: json['hasDisability'] == true,
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
    _signals.close();
    super.dispose();
  }
}
