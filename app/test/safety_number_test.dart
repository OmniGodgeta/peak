import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:peak/crypto/safety_number.dart';

void main() {
  SafetyDevice dev(String acct, String id, int keyByte) => SafetyDevice(
    accountId: acct,
    deviceId: id,
    signatureKey: Uint8List.fromList(List.filled(32, keyByte)),
  );

  final alice = dev('alice', 'phone', 1);
  final bob = dev('bob', 'phone', 2);

  test('60 digits in 12 groups of 5', () async {
    final n = await safetyNumber('conv', [alice, bob]);
    expect(n, hasLength(12));
    expect(n.every((g) => RegExp(r'^\d{5}$').hasMatch(g)), isTrue);
  });

  test('every member computes the same number, whatever the order', () async {
    expect(
      await safetyNumber('conv', [alice, bob]),
      await safetyNumber('conv', [bob, alice]),
    );
  });

  test('a swapped key, an extra device or another chat changes it', () async {
    final base = await safetyNumber('conv', [alice, bob]);
    expect(
      await safetyNumber('conv', [alice, dev('bob', 'phone', 3)]),
      isNot(base),
    );
    expect(
      await safetyNumber('conv', [alice, bob, dev('bob', 'tablet', 4)]),
      isNot(base),
    );
    expect(await safetyNumber('other', [alice, bob]), isNot(base));
  });

  test('identities parse as account:device', () {
    final d = SafetyDevice.fromMember(
      Uint8List.fromList('acct-1:dev-2'.codeUnits),
      Uint8List(32),
    );
    expect(d.accountId, 'acct-1');
    expect(d.deviceId, 'dev-2');
  });
}
