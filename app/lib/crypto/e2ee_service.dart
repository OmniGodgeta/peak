import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/env.dart';
import '../data/supabase_providers.dart';
import 'device_repository.dart';
import 'mls/mls.dart';
import 'noop_e2ee.dart';
import 'openmls_e2ee.dart';

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

  /// Try to make a brand-new conversation end-to-end encrypted: build its
  /// MLS group with every device of every other member and send the
  /// Welcomes. Returns true if the conversation is now encrypted; false
  /// (and the conversation stays plaintext) if encryption isn't available,
  /// a member has no encryption-capable device, or messages already exist.
  Future<bool> setUpConversation(
    String conversationId,
    List<String> otherMemberIds,
  );

  /// Bring this device's view of an encrypted conversation up to date:
  /// join from its Welcome if needed, apply other devices' commits, then add
  /// devices that should be in the group (new devices of members) and remove
  /// ones that shouldn't (people who left, revoked devices). 2.5-4.
  Future<void> syncConversation(String conversationId);

  /// Add a person to an encrypted group: all their devices join the MLS
  /// group and they become a member, in one step. Throws if they have no
  /// device that supports encrypted chats.
  Future<void> addMember(String conversationId, String userId);

  /// Encrypt an outgoing text message for an encrypted conversation. Once
  /// the message row exists, call [rememberSent]: the sender can never
  /// decrypt its own MLS messages.
  Future<({Uint8List ciphertext, int epoch})> encryptMessage(
    String conversationId,
    String text,
  );

  /// Keep the plaintext of a message this device sent.
  Future<void> rememberSent(String messageId, String text);

  /// The plaintext of an encrypted message, or null if this device can't read
  /// it (it joined later, or the message predates its membership). Each MLS
  /// message can be decrypted only once, so results are cached on-device.
  Future<String?> readMessage(
    String conversationId,
    String messageId,
    Uint8List ciphertext,
  );
}

/// MLS only when the build opts in (PEAK_E2EE=mls) and the native library
/// is packaged; otherwise the transport-only [NoopE2ee].
final e2eeServiceProvider = Provider<E2eeService>((ref) {
  if (Env.e2eeMls && MlsClient.available()) {
    return OpenMlsE2ee(
      ref.watch(supabaseProvider),
      ref.watch(deviceRepositoryProvider),
    );
  }
  return const NoopE2ee();
});
