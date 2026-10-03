import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A device in an encrypted conversation's MLS group.
class SafetyDevice {
  const SafetyDevice({
    required this.accountId,
    required this.deviceId,
    required this.signatureKey,
  });

  final String accountId;
  final String deviceId;
  final Uint8List signatureKey;

  /// MLS credential identities are `<account>:<device>`.
  static SafetyDevice fromMember(Uint8List identity, Uint8List key) {
    final s = utf8.decode(identity, allowMalformed: true);
    final i = s.lastIndexOf(':');
    return SafetyDevice(
      accountId: i < 0 ? s : s.substring(0, i),
      deviceId: i < 0 ? '' : s.substring(i + 1),
      signatureKey: key,
    );
  }
}

/// What the safety-number screen shows (docs/ENCRYPTION.md, 2.5-6).
class SafetyInfo {
  const SafetyInfo({
    required this.number,
    required this.devices,
    required this.notListedByServer,
    required this.notYetInGroup,
  });

  /// 12 groups of 5 digits. The same on every device in the conversation
  /// while they all see the same members and keys.
  final List<String> number;
  final List<SafetyDevice> devices;

  /// In the encrypted group, but the server doesn't list the device as one
  /// of a member's current devices (revoked, or the server is hiding it).
  final Set<String> notListedByServer;

  /// Listed by the server, not in the group yet (added on the next send).
  final Set<String> notYetInGroup;
}

/// The conversation's safety number: SHA-512 over a version tag, the
/// conversation id, and every member device's identity and signature key in
/// identity order (so every device computes the same thing). Any added,
/// removed or swapped device or key changes it. 60 digits = 12 x 5, each
/// from 5 bytes of the digest (as Signal does).
Future<List<String>> safetyNumber(
  String conversationId,
  List<SafetyDevice> devices,
) async {
  final sorted = [...devices]
    ..sort(
      (a, b) => '${a.accountId}:${a.deviceId}'.compareTo(
        '${b.accountId}:${b.deviceId}',
      ),
    );
  final b = BytesBuilder(copy: false)
    ..add(utf8.encode('peak-safety-number-v1\n$conversationId\n'));
  void field(List<int> bytes) {
    b.add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
    b.add(bytes);
  }

  for (final d in sorted) {
    field(utf8.encode('${d.accountId}:${d.deviceId}'));
    field(d.signatureKey);
  }
  final digest = (await Sha512().hash(b.toBytes())).bytes;
  return [
    for (var i = 0; i < 12; i++)
      (digest
                  .sublist(i * 5, i * 5 + 5)
                  .fold<int>(0, (acc, x) => acc * 256 + x) %
              100000)
          .toString()
          .padLeft(5, '0'),
  ];
}
