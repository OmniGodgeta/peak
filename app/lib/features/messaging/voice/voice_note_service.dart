import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class VoiceNoteService {
  final _recorder = AudioRecorder();

  Future<bool> get isRecording async => _recorder.isRecording();

  Future<void> startRecording() async {
    if (await _recorder.hasPermission()) {
      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
    } else {
      throw Exception('Microphone permission denied');
    }
  }

  // Does not dispose the recorder — one VoiceNoteService instance lives for
  // the whole chat session and records more than once. dispose() below is
  // for when the screen itself closes.
  Future<File?> stopRecording() async {
    final path = await _recorder.stop();
    return path != null ? File(path) : null;
  }

  void dispose() {
    _recorder.dispose();
  }
}
