import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/call_repository.dart';
import '../../data/supabase_providers.dart';
import 'call_media.dart';

/// A multi-party room inside a Space, built on the same signaling approach
/// as the 1:1 CallRoomScreen (a Supabase Realtime broadcast channel per
/// room), generalized to a full-mesh topology: every participant holds one
/// RTCPeerConnection per OTHER participant. This is the standard approach
/// for small group calls without a dedicated SFU - fine up to a handful of
/// people (call_rooms.max_participants defaults to 4), not meant to scale
/// to large audiences. With video on, each person uploads one stream per
/// other person, which is why the cap stays small.
///
/// Join protocol (avoids every peer racing to offer every other peer at
/// once): a new joiner broadcasts `peer-join` once its channel is joined.
/// Every participant ALREADY in the room, on seeing that, is the one who
/// creates the new peer connection and sends the offer - not the joiner.
/// The joiner only ever answers. This keeps a single fixed direction per
/// pair (existing member offers, joiner answers).
///
/// Video: each pair negotiates one video slot up front (see [VideoSlot]);
/// camera / screen share are swapped into every slot with replaceTrack, so
/// toggling never renegotiates. `peer-video` tells the others what to show.
///
/// Not verified on physical devices (none available in this environment) -
/// a multi-party call fundamentally needs 3+ live endpoints to test the
/// mesh end to end, so this is correct by API-doc verification and code
/// review, not a confirmed live test.
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
  VideoSlot? slot;
  final renderer = RTCVideoRenderer();
  MediaStream? videoStream;
  VideoSource source = VideoSource.none;

  Future<void> dispose() async {
    await pc?.close();
    await pc?.dispose();
    await videoStream?.dispose();
    await renderer.dispose();
  }
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

  final _local = LocalVideo();
  final _localRenderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _myId = ref.read(supabaseProvider).auth.currentUser!.id;
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _setup();
  }

  Future<void> _setup() async {
    try {
      final repo = ref.read(callRepositoryProvider);
      await repo.joinRoom(widget.roomId);

      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

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
          event: 'peer-video',
          callback: (payload) {
            final uid = payload['uid'] as String?;
            final state = uid == null ? null : _peers[uid];
            if (state == null || !mounted) return;
            setState(
              () => state.source = VideoSource.values.firstWhere(
                (v) => v.name == payload['source'],
                orElse: () => VideoSource.none,
              ),
            );
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
      // Announce only once joined; a broadcast sent before that can be lost
      // and nobody would ever offer to us.
      _channel!.subscribe((status, _) {
        if (status != RealtimeSubscribeStatus.subscribed) return;
        if (mounted) setState(() => _joined = true);
        _channel!.sendBroadcastMessage(
          event: 'peer-join',
          payload: {'uid': _myId},
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not join room: $e');
    }
  }

  Future<RTCPeerConnection> _createPeerConnection(
    String peerId,
    _PeerConnectionState state,
  ) async {
    await state.renderer.initialize();
    final pc = await createPeerConnection(callRtcConfig());
    for (final track in _localStream!.getAudioTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _channel?.sendBroadcastMessage(
        event: 'peer-ice',
        payload: {
          'from': _myId,
          'target': peerId,
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      );
    };
    pc.onTrack = (event) async {
      if (event.track.kind != 'video') return;
      final s =
          state.videoStream ?? await createLocalMediaStream('peer-$peerId');
      await s.addTrack(event.track);
      state.videoStream = s;
      state.renderer.srcObject = s;
      if (mounted) setState(() {});
    };
    pc.onConnectionState = (s) {
      // Tell the newcomer what we're already showing.
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _announceVideo();
      }
    };
    return pc;
  }

  Future<void> _offerTo(String peerId) async {
    final state = _PeerConnectionState();
    _peers[peerId] = state;
    final pc = await _createPeerConnection(peerId, state);
    state.pc = pc;
    state.slot = await VideoSlot.add(pc);
    await state.slot!.send(_local.track);
    if (mounted) setState(() {});

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _channel?.sendBroadcastMessage(
      event: 'peer-offer',
      payload: {
        'from': _myId,
        'target': peerId,
        'sdp': offer.sdp,
        'type': offer.type,
      },
    );
  }

  Future<void> _onOffer(String from, Map<String, dynamic> payload) async {
    final state = _peers[from] ?? _PeerConnectionState();
    _peers[from] = state;
    final pc = state.pc ?? await _createPeerConnection(from, state);
    state.pc = pc;
    if (mounted) setState(() {});

    await pc.setRemoteDescription(
      RTCSessionDescription(
        payload['sdp'] as String,
        payload['type'] as String,
      ),
    );
    state.remoteDescriptionSet = true;
    await _flushPendingCandidates(state);
    state.slot = await VideoSlot.claim(pc);
    await state.slot?.send(_local.track);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _channel?.sendBroadcastMessage(
      event: 'peer-answer',
      payload: {
        'from': _myId,
        'target': from,
        'sdp': answer.sdp,
        'type': answer.type,
      },
    );
  }

  Future<void> _onAnswer(String from, Map<String, dynamic> payload) async {
    final state = _peers[from];
    final pc = state?.pc;
    if (state == null || pc == null) return;
    await pc.setRemoteDescription(
      RTCSessionDescription(
        payload['sdp'] as String,
        payload['type'] as String,
      ),
    );
    state.remoteDescriptionSet = true;
    await _flushPendingCandidates(state);
  }

  Future<void> _onRemoteCandidate(
    String from,
    Map<String, dynamic> payload,
  ) async {
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
    state?.dispose();
    if (mounted) setState(() {});
  }

  void _announceVideo() {
    _channel?.sendBroadcastMessage(
      event: 'peer-video',
      payload: {'uid': _myId, 'source': _local.source.name},
    );
  }

  Future<void> _setVideo(VideoSource want) async {
    try {
      if (want == VideoSource.none || want == _local.source) {
        await _local.stop();
      } else if (want == VideoSource.camera) {
        await _local.startCamera();
      } else {
        await _local.startScreen();
      }
    } catch (e) {
      await _local.stop();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't start video: $e")));
      }
    }
    for (final p in _peers.values) {
      await p.slot?.send(_local.track);
    }
    _localRenderer.srcObject = _local.stream;
    _announceVideo();
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
    _channel?.sendBroadcastMessage(
      event: 'peer-leave',
      payload: {'uid': _myId},
    );
    await _cleanup();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _cleanup() async {
    await ref.read(callRepositoryProvider).leaveRoom(widget.roomId);
    await _channel?.unsubscribe();
    for (final peerId in _peers.keys.toList()) {
      _removePeer(peerId);
    }
    await _local.stop();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    await _localRenderer.dispose();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  Widget _tile({
    required String label,
    required RTCVideoRenderer renderer,
    required VideoSource source,
    bool mirror = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: source == VideoSource.none
            ? scheme.surfaceContainerHigh
            : Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (source == VideoSource.none)
              const Icon(Icons.person, size: 48)
            else
              RTCVideoView(
                renderer,
                mirror: mirror,
                objectFit: source == VideoSource.screen
                    ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                    : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: Colors.black54,
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final peers = _peers.values.toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : !_joined
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    peers.isEmpty
                        ? 'Waiting for others to join…'
                        : '${peers.length + 1} in the room',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: GridView.count(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    crossAxisCount: peers.isEmpty ? 1 : 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 3 / 4,
                    children: [
                      _tile(
                        label: 'You',
                        renderer: _localRenderer,
                        source: _local.source,
                        mirror: _local.source == VideoSource.camera,
                      ),
                      for (var i = 0; i < peers.length; i++)
                        _tile(
                          label: 'Guest ${i + 1}',
                          renderer: peers[i].renderer,
                          source: peers[i].source,
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 16,
                    runSpacing: 12,
                    children: [
                      _RoomButton(
                        icon: _muted ? Icons.mic_off : Icons.mic,
                        active: _muted,
                        label: _muted ? 'Unmute' : 'Mute',
                        onPressed: _toggleMute,
                      ),
                      _RoomButton(
                        icon: _local.source == VideoSource.camera
                            ? Icons.videocam
                            : Icons.videocam_off,
                        active: _local.source == VideoSource.camera,
                        label: 'Camera',
                        onPressed: () => _setVideo(VideoSource.camera),
                      ),
                      if (_local.source == VideoSource.camera)
                        _RoomButton(
                          icon: Icons.cameraswitch,
                          active: false,
                          label: 'Flip',
                          onPressed: () async {
                            await _local.flipCamera();
                            if (mounted) setState(() {});
                          },
                        ),
                      _RoomButton(
                        icon: Icons.screen_share,
                        active: _local.source == VideoSource.screen,
                        label: 'Share',
                        onPressed: () => _setVideo(VideoSource.screen),
                      ),
                      _RoomButton(
                        icon: Icons.volume_up,
                        active: _speakerOn,
                        label: 'Speaker',
                        onPressed: _toggleSpeaker,
                      ),
                      _RoomButton(
                        icon: Icons.call_end,
                        active: false,
                        color: Colors.red,
                        label: 'Leave',
                        onPressed: _leaveRoom,
                      ),
                    ],
                  ),
                ),
              ],
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
