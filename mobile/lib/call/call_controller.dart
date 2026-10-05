import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../live/live_location_client.dart';

enum CallPhase { idle, calling, ringing, connecting, connected }

/// One-to-one audio call over WebRTC. Signalling goes through [LiveLocationClient];
/// media flows peer to peer, using public STUN to find a route (no TURN relay).
class CallController extends ChangeNotifier {
  CallController({required this.client}) {
    _signalSub = client.signals.listen(_onSignal);
  }

  static const _config = <String, dynamic>{
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
        ],
      },
    ],
    'sdpSemantics': 'unified-plan',
  };
  static const _ringTimeout = Duration(seconds: 30);

  final LiveLocationClient client;
  late final StreamSubscription<CallSignal> _signalSub;
  final _notices = StreamController<String>.broadcast();

  CallPhase _phase = CallPhase.idle;
  String? _callId;
  String? _peerId;
  String _peerName = '';
  bool _incoming = false;
  bool _muted = false;
  bool _speaker = true;
  DateTime? _connectedAt;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  RTCSessionDescription? _offer;
  bool _remoteSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  Timer? _ringTimer;

  CallPhase get phase => _phase;
  bool get isIdle => _phase == CallPhase.idle;
  String get peerName => _peerName;
  bool get incoming => _incoming;
  bool get muted => _muted;
  bool get speaker => _speaker;
  DateTime? get connectedAt => _connectedAt;

  /// Short messages explaining why a call ended or couldn't start.
  Stream<String> get notices => _notices.stream;

  // --- caller (admin) ------------------------------------------------------

  Future<void> startCall({required String userId, required String name}) async {
    if (!isIdle) return;
    if (!client.isOnline(userId)) {
      _notices.add('$name is offline');
      return;
    }

    _begin(callId: _newId(), peerId: userId, peerName: name, incoming: false);
    _setPhase(CallPhase.calling);

    try {
      await _createPeer();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      final sent = client.sendSignal(
        to: userId,
        callId: _callId!,
        kind: 'offer',
        data: {'sdp': offer.sdp, 'type': offer.type},
      );
      if (!sent) throw StateError('not connected');
      _ringTimer = Timer(_ringTimeout, () => _end('No answer', signal: 'hangup'));
    } catch (e) {
      debugPrint('[call] start failed: $e');
      _end('Could not start the call', signal: 'hangup');
    }
  }

  // --- callee (employee) ---------------------------------------------------

  Future<void> accept() async {
    final offer = _offer;
    if (_phase != CallPhase.ringing || offer == null) return;
    _ringTimer?.cancel();
    _setPhase(CallPhase.connecting);

    try {
      await _createPeer();
      await _pc!.setRemoteDescription(offer);
      _remoteSet = true;
      await _flushCandidates();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      client.sendSignal(
        to: _peerId!,
        callId: _callId!,
        kind: 'answer',
        data: {'sdp': answer.sdp, 'type': answer.type},
      );
    } catch (e) {
      debugPrint('[call] accept failed: $e');
      _end('Could not answer the call', signal: 'reject');
    }
  }

  void decline() {
    if (_phase == CallPhase.ringing) _end(null, signal: 'reject');
  }

  // --- both ----------------------------------------------------------------

  void hangUp() {
    if (isIdle) return;
    _end(null, signal: 'hangup');
  }

  void toggleMute() {
    _muted = !_muted;
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !_muted;
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    _speaker = !_speaker;
    notifyListeners();
    await _applySpeaker();
  }

  Future<void> _applySpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(_speaker);
    } catch (e) {
      debugPrint('[call] speaker routing unavailable: $e');
    }
  }

  // --- signalling ----------------------------------------------------------

  void _onSignal(CallSignal s) {
    switch (s.kind) {
      case 'offer':
        _onOffer(s);
      case 'answer':
        if (s.callId == _callId && _phase == CallPhase.calling) _onAnswer(s);
      case 'candidate':
        if (s.callId == _callId) _onCandidate(s);
      case 'unavailable':
        if (s.callId == _callId) _end('$_peerName is offline');
      case 'reject':
        if (s.callId == _callId) {
          _end(s.data?['reason'] == 'busy' ? '$_peerName is on another call' : '$_peerName declined');
        }
      case 'hangup':
        if (s.callId == _callId) _end(_phase == CallPhase.ringing ? 'Missed call from $_peerName' : 'Call ended');
    }
  }

  void _onOffer(CallSignal s) {
    final sdp = s.data?['sdp'] as String?;
    if (s.fromRole != 'admin' || sdp == null) return;

    if (!isIdle) {
      client.sendSignal(to: s.from, callId: s.callId, kind: 'reject', data: {'reason': 'busy'});
      return;
    }
    _begin(callId: s.callId, peerId: s.from, peerName: s.fromName, incoming: true);
    _offer = RTCSessionDescription(sdp, s.data?['type'] as String? ?? 'offer');
    _setPhase(CallPhase.ringing);
    _ringTimer = Timer(_ringTimeout + const Duration(seconds: 5), () => _end('Missed call from $_peerName'));
  }

  Future<void> _onAnswer(CallSignal s) async {
    final sdp = s.data?['sdp'] as String?;
    final pc = _pc;
    if (sdp == null || pc == null) return;
    _ringTimer?.cancel();
    _setPhase(CallPhase.connecting);
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, s.data?['type'] as String? ?? 'answer'));
      _remoteSet = true;
      await _flushCandidates();
    } catch (e) {
      debugPrint('[call] bad answer: $e');
      _end('Call failed', signal: 'hangup');
    }
  }

  Future<void> _onCandidate(CallSignal s) async {
    final data = s.data;
    final candidate = data?['candidate'] as String?;
    if (candidate == null) return;
    final ice = RTCIceCandidate(
      candidate,
      data?['sdpMid'] as String?,
      (data?['sdpMLineIndex'] as num?)?.toInt(),
    );
    // Candidates can beat the SDP: hold them until a remote description exists.
    if (_pc != null && _remoteSet) {
      try {
        await _pc!.addCandidate(ice);
      } catch (e) {
        debugPrint('[call] addCandidate failed: $e');
      }
    } else {
      _pendingCandidates.add(ice);
    }
  }

  Future<void> _flushCandidates() async {
    final pending = List.of(_pendingCandidates);
    _pendingCandidates.clear();
    for (final c in pending) {
      await _pc?.addCandidate(c);
    }
  }

  // --- peer connection -----------------------------------------------------

  Future<void> _createPeer() async {
    final stream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final pc = await createPeerConnection(_config);
    _local = stream;
    _pc = pc;

    for (final track in stream.getAudioTracks()) {
      await pc.addTrack(track, stream);
    }

    pc.onIceCandidate = (c) {
      final peer = _peerId, id = _callId;
      if (c.candidate == null || peer == null || id == null) return;
      client.sendSignal(to: peer, callId: id, kind: 'candidate', data: c.toMap());
    };
    pc.onConnectionState = (state) {
      if (_pc != pc) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          if (_phase == CallPhase.connected) return;
          _ringTimer?.cancel();
          _connectedAt = DateTime.now();
          _setPhase(CallPhase.connected);
          _applySpeaker();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _end('Connection failed', signal: 'hangup');
        default:
      }
    };
  }

  // --- lifecycle -----------------------------------------------------------

  void _begin({
    required String callId,
    required String peerId,
    required String peerName,
    required bool incoming,
  }) {
    _callId = callId;
    _peerId = peerId;
    _peerName = peerName;
    _incoming = incoming;
    _muted = false;
    _connectedAt = null;
  }

  void _end(String? notice, {String? signal}) {
    if (isIdle) return;

    final peer = _peerId, id = _callId;
    if (signal != null && peer != null && id != null) {
      client.sendSignal(to: peer, callId: id, kind: signal);
    }

    _ringTimer?.cancel();
    final pc = _pc, local = _local;
    _pc = null;
    _local = null;
    _offer = null;
    _remoteSet = false;
    _pendingCandidates.clear();
    _callId = null;
    _peerId = null;
    _connectedAt = null;
    unawaited(_release(pc, local));

    if (notice != null) _notices.add(notice);
    _setPhase(CallPhase.idle);
  }

  Future<void> _release(RTCPeerConnection? pc, MediaStream? local) async {
    try {
      for (final t in local?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await local?.dispose();
      await pc?.close();
      await pc?.dispose();
    } catch (e) {
      debugPrint('[call] cleanup failed: $e');
    }
  }

  void _setPhase(CallPhase next) {
    _phase = next;
    notifyListeners();
  }

  static String _newId() {
    final rng = Random.secure();
    return List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void dispose() {
    _end(null, signal: 'hangup');
    _signalSub.cancel();
    _notices.close();
    super.dispose();
  }
}
