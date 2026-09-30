// Round-trips real MLS through the native OpenMLS library via dart:ffi.
// Needs the host build: `tool/build_mls.sh` (or `cargo build --release` in
// native/peak_mls). Skipped when it isn't there (e.g. CI without Rust).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:peak/crypto/mls/mls.dart';

void main() {
  final lib =
      Platform.environment['PEAK_MLS_LIB'] ??
      '${Directory.current.path}/../native/peak_mls/target/release/libpeak_mls.so';
  final skip = File(lib).existsSync() ? false : 'native MLS library not built';

  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  test('two devices exchange messages; state survives a restart', () {
    final alice = MlsClient.create(b('alice:phone'), libraryPath: lib);
    final bob = MlsClient.create(b('bob:phone'), libraryPath: lib);
    final gid = b('conversation-1');

    alice.createGroup(gid);
    final (_, welcome) = alice.addMembers(gid, [bob.keyPackage()]);
    expect(bob.join(welcome), gid);

    final ct = alice.encrypt(gid, b('hello bob'));
    expect(
      utf8.decode(ct, allowMalformed: true).contains('hello bob'),
      isFalse,
    );
    final got = bob.process(gid, ct);
    expect(got, isA<MlsApplication>());
    expect(utf8.decode((got as MlsApplication).plaintext), 'hello bob');

    // "Restart": save both, drop them, load again, keep talking.
    final aState = alice.save(), bState = bob.save();
    alice.dispose();
    bob.dispose();
    final alice2 = MlsClient.load(aState, libraryPath: lib);
    final bob2 = MlsClient.load(bState, libraryPath: lib);
    final back = bob2.encrypt(gid, b('hi alice'));
    expect(
      utf8.decode((alice2.process(gid, back) as MlsApplication).plaintext),
      'hi alice',
    );
    expect(alice2.epoch(gid), bob2.epoch(gid));
    expect(alice2.members(gid).map(utf8.decode).toSet(), {
      'alice:phone',
      'bob:phone',
    });
    alice2.dispose();
    bob2.dispose();
  }, skip: skip);

  test('errors come back as MlsException, never a crash', () {
    final c = MlsClient.create(b('x:y'), libraryPath: lib);
    expect(
      () => c.process(b('nope'), b('garbage')),
      throwsA(isA<MlsException>()),
    );
    expect(
      () => MlsClient.load(b('not a state'), libraryPath: lib),
      throwsA(isA<MlsException>()),
    );
    c.dispose();
    expect(() => c.save(), throwsStateError);
  }, skip: skip);

  test('list packing round-trips', () {
    final items = [b('a'), Uint8List(0), b('longer item')];
    expect(mlsUnpackList(mlsPackList(items)).map(utf8.decode).toList(), [
      'a',
      '',
      'longer item',
    ]);
  });
}
