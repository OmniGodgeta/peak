import 'dart:typed_data';

import 'e2ee_service.dart';
import 'safety_number.dart';

/// Transport-only fallback — this is the current Phase 2 behaviour made
/// explicit. Messages travel over TLS but the server can read their content.
/// The UI must surface this (no "end-to-end encrypted" claim) while it's active.
class NoopE2ee implements E2eeService {
  const NoopE2ee();

  @override
  bool get available => false;

  @override
  Future<void> ensureDeviceRegistered() async {}

  @override
  Future<bool> setUpConversation(
    String conversationId,
    List<String> otherMemberIds,
  ) async => false;

  @override
  Future<void> syncConversation(String conversationId) async {}

  @override
  Future<void> addMember(String conversationId, String userId) async =>
      throw UnsupportedError(
        'Encrypted conversations need the MLS build (PEAK_E2EE=mls).',
      );

  @override
  Future<SafetyInfo?> safetyInfo(String conversationId) async => null;

  @override
  Future<({Uint8List ciphertext, int epoch})> encryptMessage(
    String conversationId,
    String text,
  ) async => throw UnsupportedError(
    'Encrypted conversations need the MLS build (PEAK_E2EE=mls).',
  );

  @override
  Future<void> rememberSent(String messageId, String text) async {}

  @override
  Future<String?> readMessage(
    String conversationId,
    String messageId,
    Uint8List ciphertext,
  ) async => null;
}
