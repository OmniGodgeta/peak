import 'package:flutter/foundation.dart';

class VoiceNoteService {
  Future<void> sendVoiceNote(String conversationId, String filePath) async {
    // TODO: Implement voice note sending logic
    // Note: MLS encryption is blocked due to missing Rust toolchain (rustup, cargo-ndk).
    debugPrint('Sending voice note for $conversationId at $filePath');
  }

  Future<bool> isDisappearingEnabled(String conversationId) async {
    // TODO: Check if disappearing messages are enabled for this conversation
    return true;
  }
}
