import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/call_repository.dart';
import '../../data/supabase_providers.dart';

/// A multi-party audio room inside a Space, built on the same signaling
/// approach as the 1:1 CallRoomScreen (a Supabase Realtime broadcast
/// channel per room), generalized to a full-mesh topology: every
/// participant holds one RTCPeerConnection per OTHER participant. This is
/// the standard approach for small group calls without a dedicated SFU -
/// fine up to a handful of people (call_rooms.max_participants defaults to
/// 4), not meant to scale to large audiences.
///
/// Join protocol (avoids every peer racing to offer every other peer at
/// once): a new joiner broadcasts `peer-join`. Every participant ALREADY in
/// the room, on seeing that, is the one who creates the new peer connection
/// and sends the offer - not the joiner. The joiner only ever answers. This
/// keeps a single fixed direction per pair (existing member offers, joiner
/// answers) instead of two peers both trying to initiate at once.
///
/// Not verified on a physical device (none available in this environment) -
/// a multi-party call fundamentally needs 3+ live endpoints to test the
/// mesh topology end to end, so this is correct by API-doc verification and
/// code review, not a confirmed live test.
class LiveRoomScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String title;

  const LiveRoomScreen({super.key, required this.roomId, required this.title});

  @override
  ConsumerState<LiveRoomScreen> createState() => _LiveRoomScreenState();
}

class _PeerConnectionState {
  RTCPeerConnection? pc;
  bool remoteDescriptionSet = false;
  final List<RTCIceCandidate> pendingCandidates = [];
}

class _LiveRoomScreenState extends ConsumerState<LiveRoomScreen> {
  late final String _myId;
  MediaStream? _localStream;
  RealtimeChannel? _channel;
  final Map<String, _PeerConnectionState> _peers = {};
  bool _muted = false;
  bool _speakerOn = false;
  bool _joined = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _myId = ref.read(supabaseProvider).auth.currentUser!.id;
    _setup();
  }

  Future<void> _setup() async {
    try {
      final repo = ref.read(callRepositoryProvider);
      await repo.joinRoom(widget.roomId);

      _localStream =
          await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});

      _channel = repo.signalingChannel(widget.roomId)
        ..onBroadcast(
          event: 'peer-join',
          callback: (payload) {
            final uid = payload['uid'] as String?;
            if (uid == null || uid == _myId || _peers.containsKey(uid)) return;
            _offerTo(uid);
          },
        )
        ..onBroadcast(
          event: 'peer-offer',
          callback: (payload) {
            if (payload['target'] != _myId) return;
            final from = payload['from'] as String?;
            if (from == null) return;
            _onOffer(from, payload);
          },
        )
        ..onBroadcast(
          event: 'peer-answer',
          callback: (payload) {
            if (payload['target'] != _myId) return;
            final from = payload['from'] as String?;
            if (from == null) return;
            _onAnswer(from, payload);
          },
        )
        ..onBroadcast(
          event: 'peer-ice',
          callback: (payload) {
            if (payload['target'] != _myId) return;
            final from = payload['from'] as String?;
            if (from == null) return;
            _onRemoteCandidate(from, payload);
          },
        )
        ..onBroadcast(
          event: 'peer-leave',
          callback: (payload) {
            final uid = payload['uid'] as String?;
            if (uid == null) return;
            _removePeer(uid);
          },
        );
      _channel!.subscribe();

      if (mounted) setState(() => _joined = true);
      _channel!.sendBroadcastMessage(event: 'peer-join', payload: {'uid': _myId});
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not join room: $e');
    }
  }

  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {
          'urls': ['stun:stun.l.google.com:19302']
        }
      ],
    });
    for (final track in _localStream!.getAudioTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _channel?.sendBroadcastMessage(event: 'peer-ice', payload: {
        'from': _myId,
        'target': peerId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    return pc;
  }

  Future<void> _offerTo(String peerId) async {
    final state = _PeerConnectionState();
    _peers[peerId] = state;
    final pc = await _createPeerConnection(peerId);
    state.pc = pc;
    if (mounted) setState(() {});

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _channel?.sendBroadcastMessage(event: 'peer-offer', payload: {
      'from': _myId,
      'target': peerId,
      'sdp': offer.sdp,
      'type': offer.type,
    });
  }

  Future<void> _onOffer(String from, Map<String, dynamic> payload) async {
    final state = _peers[from] ?? _PeerConnectionState();
    _peers[from] = state;
    final pc = state.pc ?? await _createPeerConnection(from);
    state.pc = pc;
    if (mounted) setState(() {});

    await pc.setRemoteDescription(
      RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
    );
    state.remoteDescriptionSet = true;
    await _flushPendingCandidates(state);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _channel?.sendBroadcastMessage(event: 'peer-answer', payload: {
      'from': _myId,
      'target': from,
      'sdp': answer.sdp,
      'type': answer.type,
    });
  }

  Future<void> _onAnswer(String from, Map<String, dynamic> payload) async {
    final state = _peers[from];
    final pc = state?.pc;
    if (state == null || pc == null) return;
    await pc.setRemoteDescription(
      RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
    );
    state.remoteDescriptionSet = true;
    await _flushPendingCandidates(state);
  }

  Future<void> _onRemoteCandidate(String from, Map<String, dynamic> payload) async {
    final state = _peers[from];
    if (state == null) return;
    final candidate = RTCIceCandidate(
      payload['candidate'] as String?,
      payload['sdpMid'] as String?,
      payload['sdpMLineIndex'] as int?,
    );
    if (!state.remoteDescriptionSet) {
      state.pendingCandidates.add(candidate);
      return;
    }
    await state.pc?.addCandidate(candidate);
  }

  Future<void> _flushPendingCandidates(_PeerConnectionState state) async {
    for (final c in state.pendingCandidates) {
      await state.pc?.addCandidate(c);
    }
    state.pendingCandidates.clear();
  }

  void _removePeer(String peerId) {
    final state = _peers.remove(peerId);
    state?.pc?.close();
    state?.pc?.dispose();
    if (mounted) setState(() {});
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

  Future<void> _leaveRoom() async {
    _channel?.sendBroadcastMessage(event: 'peer-leave', payload: {'uid': _myId});
    await _cleanup();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _cleanup() async {
    await ref.read(callRepositoryProvider).leaveRoom(widget.roomId);
    await _channel?.unsubscribe();
    for (final peerId in _peers.keys.toList()) {
      _removePeer(peerId);
    }
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
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
            : !_joined
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.groups, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        _peers.isEmpty
                            ? 'Waiting for others to join…'
                            : '${_peers.length + 1} in the room',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 48),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _RoomButton(
                            icon: _muted ? Icons.mic_off : Icons.mic,
                            active: _muted,
                            label: _muted ? 'Unmute' : 'Mute',
                            onPressed: _toggleMute,
                          ),
                          const SizedBox(width: 20),
                          _RoomButton(
                            icon: Icons.volume_up,
                            active: _speakerOn,
                            label: 'Speaker',
                            onPressed: _toggleSpeaker,
                          ),
                          const SizedBox(width: 20),
                          _RoomButton(
                            icon: Icons.call_end,
                            active: false,
                            color: Colors.red,
                            label: 'Leave',
                            onPressed: _leaveRoom,
                          ),
                        ],
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _RoomButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color? color;
  final String label;
  final VoidCallback onPressed;

  const _RoomButton({
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
          backgroundColor:
              color ?? (active ? scheme.primary : scheme.surfaceContainerHigh),
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
