import 'package:flutter/foundation.dart';

class DisappearingMessageService {
  Future<void> setDisappearingMessages(String conversationId, bool enabled) async {
    // TODO: Implement disappearing messages settings logic
    // Note: MLS encryption is blocked due to missing Rust toolchain (rustup, cargo-ndk).
    debugPrint('Setting disappearing messages for $conversationId to $enabled');
  }

  Future<bool> checkStatus(String conversationId) async {
    // TODO: Check if disappearance mode is active
    return true;
  }
}
