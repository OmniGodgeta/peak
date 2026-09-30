import 'dart:typed_data';

import 'package:image_picker/image_picker.dart' show XFile;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// A finished recording, ready to attach to a post.
class RecordedAudio {
  const RecordedAudio({
    required this.bytes,
    required this.mimeType,
    required this.duration,
  });

  final Uint8List bytes;
  final String mimeType;
  final Duration duration;
}

/// Records one audio post. AAC in an .m4a on phones; browsers can't encode
/// AAC, so the web build records Opus in WebM.
class AudioPostRecorder {
  final _recorder = AudioRecorder();
  DateTime? _startedAt;

  static const maxLength = Duration(minutes: 10);

  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw Exception('Microphone permission denied');
    }
    final String path;
    final RecordConfig config;
    if (kIsWeb) {
      path = '';
      config = const RecordConfig(encoder: AudioEncoder.opus);
    } else {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/post-${DateTime.now().millisecondsSinceEpoch}.m4a';
      config = const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000);
    }
    await _recorder.start(config, path: path);
    _startedAt = DateTime.now();
  }

  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  /// Stops and returns the recording, or null if nothing was captured.
  Future<RecordedAudio?> stop() async {
    final duration = elapsed;
    _startedAt = null;
    final out = await _recorder.stop();
    if (out == null) return null;
    // On web `out` is a blob: URL; elsewhere a file path. XFile reads both.
    final bytes = await XFile(out).readAsBytes();
    if (bytes.isEmpty) return null;
    return RecordedAudio(
      bytes: bytes,
      mimeType: kIsWeb ? 'audio/webm' : 'audio/mp4',
      duration: duration,
    );
  }

  Future<void> cancel() async {
    _startedAt = null;
    await _recorder.cancel();
  }

  void dispose() => _recorder.dispose();
}
