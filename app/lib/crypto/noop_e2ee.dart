import 'dart:typed_data';

import 'e2ee_service.dart';

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
  Future<void> createGroup(
    String conversationId,
    List<String> memberAccountIds,
  ) async {
    throw UnsupportedError(
      'Encrypted conversations require the MLS build (Phase 2.5).',
    );
  }

  @override
  Future<Uint8List> encrypt(String conversationId, Uint8List plaintext) async =>
      plaintext;

  @override
  Future<Uint8List> decrypt(
    String conversationId,
    Uint8List ciphertext,
  ) async => ciphertext;
}
