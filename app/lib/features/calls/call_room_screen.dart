import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/call_repository.dart';
import '../../data/supabase_providers.dart';
import 'call_media.dart';

enum _CallState { connecting, ringing, connected, ended, failed }

/// A real 1:1 local audio call over WebRTC, signaled through a Supabase
/// Realtime broadcast channel (`CallRepository.signalingChannel`) instead of
/// a dedicated signaling server. Only STUN (Google's public server) is
/// configured, no TURN - calls between two devices both behind restrictive/
/// symmetric NAT may fail to connect unless a TURN relay is configured
/// (TURN_URL / TURN_USERNAME / TURN_CREDENTIAL build defines). Audio, plus
/// camera or screen share in the call's one video slot (see [VideoSlot]):
/// toggling swaps the track, it never renegotiates.
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

  final _local = LocalVideo();
  VideoSlot? _videoSlot;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  MediaStream? _remoteVideoStream;
  VideoSource _remoteSource = VideoSource.none;

  @override
  void initState() {
    super.initState();
    _myId = ref.read(supabaseProvider).auth.currentUser!.id;
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    await _setup();
  }

  Future<void> _setup() async {
    try {
      final repo = ref.read(callRepositoryProvider);
      final ownerId = await repo.roomOwnerId(widget.roomId);
      _isOfferer = ownerId == _myId;

      await repo.joinRoom(widget.roomId);

      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

      _pc = await createPeerConnection(callRtcConfig());

      for (final track in _localStream!.getAudioTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
      if (_isOfferer) _videoSlot = await VideoSlot.add(_pc!);

      _pc!.onTrack = (event) async {
        if (event.track.kind != 'video') return;
        // The slot has no stream id of its own; wrap the track for the view.
        final s =
            _remoteVideoStream ?? await createLocalMediaStream('remote-video');
        await s.addTrack(event.track);
        _remoteVideoStream = s;
        _remoteRenderer.srcObject = s;
        if (mounted) setState(() {});
      };

      _pc!.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        _channel?.sendBroadcastMessage(
          event: 'ice-candidate',
          payload: {
            'uid': _myId,
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        );
      };

      _pc!.onConnectionState = (state) {
        if (!mounted) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          setState(() => _state = _CallState.connected);
          _announceVideo();
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
        )
        ..onBroadcast(
          event: 'video',
          callback: (payload) {
            if (payload['uid'] == _myId || !mounted) return;
            setState(
              () => _remoteSource = VideoSource.values.firstWhere(
                (v) => v.name == payload['source'],
                orElse: () => VideoSource.none,
              ),
            );
          },
        );
      // Announce readiness only once the channel is actually joined — a
      // broadcast sent before that can be dropped, leaving both sides
      // waiting forever.
      _channel!.subscribe((status, _) {
        if (status == RealtimeSubscribeStatus.subscribed && !_isOfferer) {
          _channel!.sendBroadcastMessage(
            event: 'ready',
            payload: {'uid': _myId},
          );
        }
      });

      if (mounted) {
        setState(
          () =>
              _state = _isOfferer ? _CallState.ringing : _CallState.connecting,
        );
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
    _channel?.sendBroadcastMessage(
      event: 'offer',
      payload: {'uid': _myId, 'sdp': offer.sdp, 'type': offer.type},
    );
  }

  Future<void> _onOffer(Map<String, dynamic> payload) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(
      RTCSessionDescription(
        payload['sdp'] as String,
        payload['type'] as String,
      ),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
    _videoSlot = await VideoSlot.claim(pc);
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _channel?.sendBroadcastMessage(
      event: 'answer',
      payload: {'uid': _myId, 'sdp': answer.sdp, 'type': answer.type},
    );
  }

  Future<void> _onAnswer(Map<String, dynamic> payload) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(
      RTCSessionDescription(
        payload['sdp'] as String,
        payload['type'] as String,
      ),
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

  void _announceVideo() {
    _channel?.sendBroadcastMessage(
      event: 'video',
      payload: {'uid': _myId, 'source': _local.source.name},
    );
  }

  Future<void> _setVideo(VideoSource want) async {
    final slot = _videoSlot;
    if (slot == null) return;
    try {
      if (want == VideoSource.none || want == _local.source) {
        await slot.send(null);
        await _local.stop();
      } else if (want == VideoSource.camera) {
        await _local.startCamera();
        await slot.send(_local.track);
      } else {
        await _local.startScreen();
        await slot.send(_local.track);
      }
    } catch (e) {
      await slot.send(null);
      await _local.stop();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't start video: $e")));
      }
    }
    _localRenderer.srcObject = _local.stream;
    _announceVideo();
    if (mounted) setState(() {});
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
    await _local.stop();
    await _pc?.close();
    await _pc?.dispose();
    await _localStream?.dispose();
    await _remoteVideoStream?.dispose();
    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
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
    final connected = _state == _CallState.connected;
    final canVideo = connected && _videoSlot != null;
    final showRemote = _remoteSource != VideoSource.none;
    final showLocal = _local.source != VideoSource.none;

    final controls = Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        _CallButton(
          icon: _muted ? Icons.mic_off : Icons.mic,
          active: _muted,
          label: _muted ? 'Unmute' : 'Mute',
          onPressed: _toggleMute,
        ),
        _CallButton(
          icon: _local.source == VideoSource.camera
              ? Icons.videocam
              : Icons.videocam_off,
          active: _local.source == VideoSource.camera,
          label: 'Camera',
          onPressed: canVideo ? () => _setVideo(VideoSource.camera) : null,
        ),
        if (_local.source == VideoSource.camera)
          _CallButton(
            icon: Icons.cameraswitch,
            active: false,
            label: 'Flip',
            onPressed: () async {
              await _local.flipCamera();
              if (mounted) setState(() {});
            },
          ),
        _CallButton(
          icon: Icons.screen_share,
          active: _local.source == VideoSource.screen,
          label: 'Share',
          onPressed: canVideo ? () => _setVideo(VideoSource.screen) : null,
        ),
        _CallButton(
          icon: Icons.volume_up,
          active: _speakerOn,
          label: 'Speaker',
          onPressed: _toggleSpeaker,
        ),
        _CallButton(
          icon: Icons.call_end,
          active: false,
          color: Colors.red,
          label: 'End',
          onPressed: _hangUp,
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      if (showRemote)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black,
                            child: RTCVideoView(
                              _remoteRenderer,
                              objectFit: _remoteSource == VideoSource.screen
                                  ? RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitContain
                                  : RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitCover,
                            ),
                          ),
                        )
                      else
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                connected ? Icons.call : Icons.call_made,
                                size: 72,
                              ),
                              const SizedBox(height: 24),
                              Text(
                                _statusText,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ),
                      if (showLocal)
                        Positioned(
                          right: 12,
                          top: 12,
                          width: 110,
                          height: 160,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              color: Colors.black,
                              child: RTCVideoView(
                                _localRenderer,
                                mirror: _local.source == VideoSource.camera,
                                objectFit: RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitCover,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  child: controls,
                ),
              ],
            ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color? color;
  final String label;
  final VoidCallback? onPressed;

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
