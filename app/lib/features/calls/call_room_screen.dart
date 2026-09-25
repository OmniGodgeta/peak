import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/call_repository.dart';
import '../../data/supabase_providers.dart';

enum _CallState { connecting, ringing, connected, ended, failed }

/// A real 1:1 local audio call over WebRTC, signaled through a Supabase
/// Realtime broadcast channel (`CallRepository.signalingChannel`) instead of
/// a dedicated signaling server. Only STUN (Google's public server) is
/// configured, no TURN - calls between two devices both behind restrictive/
/// symmetric NAT may fail to connect; there's no relay fallback. Audio only,
/// no video, matching the operator's "local audio calls" ask.
///
/// Role is fixed by who created the room (`call_rooms.owner_id`): the
/// creator always sends the SDP offer once someone else joins, and the
/// other participant always answers. A fixed role avoids two peers racing
/// to both send offers at once (SDP "glare"), which a symmetric join-and-
/// negotiate design would hit in a 2-party call.
///
/// Not verified on a physical device (none available in this environment) -
/// audio calls fundamentally need two real endpoints to test end to end.
class CallRoomScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String title;

  const CallRoomScreen({super.key, required this.roomId, required this.title});

  @override
  ConsumerState<CallRoomScreen> createState() => _CallRoomScreenState();
}

class _CallRoomScreenState extends ConsumerState<CallRoomScreen> {
  late final String _myId;
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RealtimeChannel? _channel;
  bool _isOfferer = false;
  bool _muted = false;
  bool _speakerOn = false;
  _CallState _state = _CallState.connecting;
  String? _error;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  @override
  void initState() {
    super.initState();
    _myId = ref.read(supabaseProvider).auth.currentUser!.id;
    _setup();
  }

  Future<void> _setup() async {
    try {
      final repo = ref.read(callRepositoryProvider);
      final ownerId = await repo.roomOwnerId(widget.roomId);
      _isOfferer = ownerId == _myId;

      await repo.joinRoom(widget.roomId);

      _localStream = await navigator.mediaDevices
          .getUserMedia({'audio': true, 'video': false});

      _pc = await createPeerConnection({
        'iceServers': [
          {
            'urls': ['stun:stun.l.google.com:19302']
          }
        ],
      });

      for (final track in _localStream!.getAudioTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      _pc!.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        _channel?.sendBroadcastMessage(event: 'ice-candidate', payload: {
          'uid': _myId,
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      };

      _pc!.onConnectionState = (state) {
        if (!mounted) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          setState(() => _state = _CallState.connected);
        } else if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          if (_state != _CallState.ended) {
            setState(() => _state = _CallState.failed);
          }
        }
      };

      _channel = repo.signalingChannel(widget.roomId)
        ..onBroadcast(
          event: 'ready',
          callback: (payload) {
            if (payload['uid'] == _myId) return;
            if (_isOfferer) _sendOffer();
          },
        )
        ..onBroadcast(
          event: 'offer',
          callback: (payload) {
            if (payload['uid'] == _myId) return;
            _onOffer(payload);
          },
        )
        ..onBroadcast(
          event: 'answer',
          callback: (payload) {
            if (payload['uid'] == _myId) return;
            _onAnswer(payload);
          },
        )
        ..onBroadcast(
          event: 'ice-candidate',
          callback: (payload) {
            if (payload['uid'] == _myId) return;
            _onRemoteCandidate(payload);
          },
        )
        ..onBroadcast(
          event: 'hangup',
          callback: (payload) {
            if (payload['uid'] == _myId) return;
            if (mounted) setState(() => _state = _CallState.ended);
          },
        );
      _channel!.subscribe();

      if (mounted) {
        setState(() => _state =
            _isOfferer ? _CallState.ringing : _CallState.connecting);
      }

      if (!_isOfferer) {
        // Announce readiness so the offerer knows someone actually joined
        // before it bothers creating an offer.
        _channel!.sendBroadcastMessage(event: 'ready', payload: {'uid': _myId});
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start call: $e');
    }
  }

  Future<void> _sendOffer() async {
    final pc = _pc;
    if (pc == null) return;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _channel?.sendBroadcastMessage(event: 'offer', payload: {
      'uid': _myId,
      'sdp': offer.sdp,
      'type': offer.type,
    });
  }

  Future<void> _onOffer(Map<String, dynamic> payload) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(
      RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _channel?.sendBroadcastMessage(event: 'answer', payload: {
      'uid': _myId,
      'sdp': answer.sdp,
      'type': answer.type,
    });
  }

  Future<void> _onAnswer(Map<String, dynamic> payload) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(
      RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
  }

  Future<void> _onRemoteCandidate(Map<String, dynamic> payload) async {
    final candidate = RTCIceCandidate(
      payload['candidate'] as String?,
      payload['sdpMid'] as String?,
      payload['sdpMLineIndex'] as int?,
    );
    // Candidates can arrive before the remote description is set (a normal
    // WebRTC race, not a bug) - queue them and add once it's ready.
    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
      return;
    }
    await _pc?.addCandidate(candidate);
  }

  Future<void> _flushPendingCandidates() async {
    for (final c in _pendingCandidates) {
      await _pc?.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  void _toggleMute() {
    final tracks = _localStream?.getAudioTracks() ?? const [];
    if (tracks.isEmpty) return;
    final track = tracks[0];
    setState(() {
      _muted = !_muted;
      track.enabled = !_muted;
    });
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _speakerOn = !_speakerOn);
    await Helper.setSpeakerphoneOn(_speakerOn);
  }

  Future<void> _hangUp() async {
    _channel?.sendBroadcastMessage(event: 'hangup', payload: {'uid': _myId});
    await _cleanup();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _cleanup() async {
    await ref.read(callRepositoryProvider).leaveRoom(widget.roomId);
    await _channel?.unsubscribe();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _pc?.close();
    await _pc?.dispose();
    await _localStream?.dispose();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  String get _statusText {
    switch (_state) {
      case _CallState.connecting:
        return 'Connecting…';
      case _CallState.ringing:
        return 'Waiting for the other person to join…';
      case _CallState.connected:
        return 'Connected';
      case _CallState.ended:
        return 'Call ended';
      case _CallState.failed:
        return 'Connection failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _state == _CallState.connected
                        ? Icons.call
                        : Icons.call_made,
                    size: 72,
                  ),
                  const SizedBox(height: 24),
                  Text(_statusText, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 48),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CallButton(
                        icon: _muted ? Icons.mic_off : Icons.mic,
                        active: _muted,
                        label: _muted ? 'Unmute' : 'Mute',
                        onPressed: _toggleMute,
                      ),
                      const SizedBox(width: 20),
                      _CallButton(
                        icon: Icons.volume_up,
                        active: _speakerOn,
                        label: 'Speaker',
                        onPressed: _toggleSpeaker,
                      ),
                      const SizedBox(width: 20),
                      _CallButton(
                        icon: Icons.call_end,
                        active: false,
                        color: Colors.red,
                        label: 'End',
                        onPressed: _hangUp,
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color? color;
  final String label;
  final VoidCallback onPressed;

  const _CallButton({
    required this.icon,
    required this.active,
    required this.label,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: color ?? (active ? scheme.primary : scheme.surfaceContainerHigh),
          child: IconButton(
            icon: Icon(icon, color: Colors.white),
            onPressed: onPressed,
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
