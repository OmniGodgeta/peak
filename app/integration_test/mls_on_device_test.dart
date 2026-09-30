// Phase 2.5-1 smoke test ON the device: the packaged libpeak_mls.so loads
// through dart:ffi and two MLS clients round-trip a message.
//   flutter test integration_test/mls_on_device_test.dart -d <device>
// Needs tool/build_mls.sh to have produced the jniLibs first.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:peak/crypto/mls/mls.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native MLS works on this device', (_) async {
    expect(
      MlsClient.available(),
      isTrue,
      reason: 'libpeak_mls.so not packaged',
    );
    Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
    final alice = MlsClient.create(b('alice:device'));
    final bob = MlsClient.create(b('bob:device'));
    final gid = b('device-smoke');
    alice.createGroup(gid);
    final (_, welcome) = alice.addMembers(gid, [bob.keyPackage()]);
    bob.join(welcome);
    final got = bob.process(gid, alice.encrypt(gid, b('on-device hello')));
    expect(utf8.decode((got as MlsApplication).plaintext), 'on-device hello');
    final restored = MlsClient.load(bob.save());
    final back = restored.encrypt(gid, b('reply'));
    expect(
      utf8.decode((alice.process(gid, back) as MlsApplication).plaintext),
      'reply',
    );
    alice.dispose();
    bob.dispose();
    restored.dispose();
  });
}
