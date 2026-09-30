import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/env.dart';

/// ICE servers for every call: STUN (overridable) plus an optional TURN relay
/// for peers behind symmetric NAT, from build defines.
Map<String, dynamic> callRtcConfig() => {
  'iceServers': [
    {
      'urls': [Env.stunUrl],
    },
    if (Env.turnUrl.isNotEmpty)
      {
        'urls': [Env.turnUrl],
        'username': Env.turnUsername,
        'credential': Env.turnCredential,
      },
  ],
};

/// What this side is sending in its video slot.
enum VideoSource { none, camera, screen }

/// A peer connection's one video slot, and what's in it.
///
/// Video is negotiated up front (the offerer adds a send/receive video
/// transceiver; the answerer claims the matching one after applying the
/// offer), so turning the camera or screen share on and off is a
/// `replaceTrack` on the sender — no renegotiation, so the fixed
/// offerer/answerer roles never race each other ("glare").
class VideoSlot {
  VideoSlot(this.sender);
  final RTCRtpSender sender;

  /// Offerer side: add the slot before creating the offer.
  static Future<VideoSlot> add(RTCPeerConnection pc) async {
    final t = await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
    );
    return VideoSlot(t.sender);
  }

  /// Answerer side: after setRemoteDescription(offer), before createAnswer.
  static Future<VideoSlot?> claim(RTCPeerConnection pc) async {
    for (final t in await pc.getTransceivers()) {
      if (t.receiver.track?.kind == 'video') {
        await t.setDirection(TransceiverDirection.SendRecv);
        return VideoSlot(t.sender);
      }
    }
    return null;
  }

  Future<void> send(MediaStreamTrack? track) => sender.replaceTrack(track);
}

/// The local camera / screen-share stream, shared by every slot on a call.
class LocalVideo {
  MediaStream? stream;
  VideoSource source = VideoSource.none;
  bool _frontCamera = true;

  static const _screen = MethodChannel('peak/screen_capture');

  MediaStreamTrack? get track {
    final s = stream;
    if (s == null) return null;
    final v = s.getVideoTracks();
    return v.isEmpty ? null : v.first;
  }

  Future<void> startCamera() async {
    await stop();
    stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': _frontCamera ? 'user' : 'environment',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      },
    });
    source = VideoSource.camera;
  }

  Future<void> flipCamera() async {
    final t = track;
    if (source != VideoSource.camera || t == null) return;
    await Helper.switchCamera(t);
    _frontCamera = !_frontCamera;
  }

  /// Android: ask for capture consent first, then start the foreground
  /// service of type mediaProjection (Android 14 refuses it before consent),
  /// then capture — flutter_webrtc reuses the consent it just got.
  Future<void> startScreen() async {
    await stop();
    if (!kIsWeb) {
      if (!await Helper.requestCapturePermission()) {
        throw Exception('Screen sharing was declined');
      }
      await _screen.invokeMethod<void>('start');
    }
    try {
      stream = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': true,
      });
      source = VideoSource.screen;
    } catch (_) {
      if (!kIsWeb) await _screen.invokeMethod<void>('stop');
      rethrow;
    }
  }

  Future<void> stop() async {
    final wasScreen = source == VideoSource.screen;
    for (final t in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await stream?.dispose();
    stream = null;
    source = VideoSource.none;
    if (wasScreen && !kIsWeb) {
      try {
        await _screen.invokeMethod<void>('stop');
      } catch (_) {}
    }
  }
}
