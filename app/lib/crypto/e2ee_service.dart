import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'noop_e2ee.dart';

/// The seam between Peak's messaging code and the encryption layer.
///
/// Phase 2 resolves this to [NoopE2ee] (plaintext — the server sees content).
/// Phase 2.5 swaps in an MLS/OpenMLS implementation; see docs/ENCRYPTION.md.
/// Nothing above this interface changes when that swap happens.
abstract class E2eeService {
  /// Whether encrypted conversations are supported on this build/device.
  bool get available;

  /// Ensure this device is registered (signature key + key-package pool).
  /// No-op until the native crypto lib is wired.
  Future<void> ensureDeviceRegistered();

  /// Establish an MLS group for a new conversation with the given members'
  /// devices. Returns the initial group state to persist server-side.
  /// Throws [UnsupportedError] in the no-op impl.
  Future<void> createGroup(
    String conversationId,
    List<String> memberAccountIds,
  );

  /// Encrypt an outgoing message for a conversation.
  /// The no-op impl returns the plaintext bytes unchanged.
  Future<Uint8List> encrypt(String conversationId, Uint8List plaintext);

  /// Decrypt an incoming ciphertext blob.
  Future<Uint8List> decrypt(String conversationId, Uint8List ciphertext);
}

final e2eeServiceProvider = Provider<E2eeService>((ref) {
  // TODO(phase-2.5-1): return OpenMlsE2ee once the native lib + FFI land.
  return const NoopE2ee();
});
