// End-to-end check of encrypted conversations (E2EE 2.5-3): two devices,
// real MLS (native OpenMLS), real SQL, real MessagingRepository, against a
// LOCAL Supabase. Creates throwaway accounts and deletes them afterwards.
//
// Opt-in (it touches the local database):
//   cd supabase && eval "$(supabase status -o env)" && cd ../app && \
//   PEAK_LOCAL_E2E=1 SUPABASE_URL=$API_URL SUPABASE_ANON=$ANON_KEY \
//   SUPABASE_SERVICE=$SERVICE_ROLE_KEY flutter test test/e2ee_conversation_local_test.dart
//
// Needs the host MLS build (tool/build_mls.sh). Never point it at hosted.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:peak/crypto/device_repository.dart';
import 'package:peak/crypto/mls/mls_state_store.dart';
import 'package:peak/crypto/openmls_e2ee.dart';
import 'package:peak/data/messaging_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _TestDevice implements DeviceRegistrar {
  _TestDevice(this._db);
  final SupabaseClient _db;
  String? _id;
  final _pub = List.generate(
    32,
    (_) => Random.secure().nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String? get thisDeviceId => _id;

  @override
  Future<String> ensureRegistered() async => _id ??= await _db.rpc(
    'register_device',
    params: {'p_public_sig_key': _pub},
  ) as String;
}

void main() {
  final env = Platform.environment;
  final lib =
      env['PEAK_MLS_LIB'] ??
      '${Directory.current.path}/../native/peak_mls/target/release/libpeak_mls.so';
  final url = env['SUPABASE_URL'] ?? '';
  final skip = env['PEAK_LOCAL_E2E'] != '1'
      ? 'set PEAK_LOCAL_E2E=1 (see header)'
      : !url.contains('127.0.0.1') && !url.contains('localhost')
      ? 'refusing to run against a non-local Supabase'
      : !File(lib).existsSync()
      ? 'native MLS library not built'
      : false;

  test(
    'two devices: encrypted DM and group; plaintext fallback',
    () async {
      final admin = SupabaseClient(url, env['SUPABASE_SERVICE']!);
      final tag = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      final created = <String>[];

      Future<({SupabaseClient db, String id})> account(String name) async {
        final email = 'e2e-$name-$tag@test.peak';
        final u = await admin.auth.admin.createUser(
          AdminUserAttributes(
            email: email,
            password: 'pw-$tag',
            emailConfirm: true,
          ),
        );
        created.add(u.user!.id);
        final db = SupabaseClient(url, env['SUPABASE_ANON']!);
        await db.auth.signInWithPassword(email: email, password: 'pw-$tag');
        await db.rpc(
          'bootstrap_account',
          params: {
            'p_handle': 'e2e$name$tag',
            'p_display_name': name,
            'p_birthdate': '1990-01-01',
          },
        );
        return (db: db, id: u.user!.id);
      }

      Future<(MessagingRepository, OpenMlsE2ee)> device(
        SupabaseClient db,
      ) async {
        final e2ee = OpenMlsE2ee(
          db,
          _TestDevice(db),
          storage: (_) => MemoryMlsStateStorage(),
          libraryPath: lib,
        );
        await e2ee.ensureDeviceRegistered(); // publishes KeyPackages
        return (MessagingRepository(db, e2ee), e2ee);
      }

      try {
        final alice = await account('alice');
        final bob = await account('bob');
        final carol = await account('carol'); // no encryption-capable device
        final (aliceRepo, _) = await device(alice.db);
        final (bobRepo, _) = await device(bob.db);

        // ── encrypted DM ──
        final dm = await aliceRepo.startDm(bob.id);
        expect(
          await aliceRepo.isEncrypted(dm),
          isTrue,
          reason: 'new DM is encrypted',
        );

        await aliceRepo.send(dm, 'hello bob, this is secret');
        final raw = await admin
            .from('message')
            .select('body, ciphertext')
            .eq('conversation_id', dm);
        expect(raw.single['body'], '', reason: 'server stores no plaintext');
        expect(
          OpenMlsE2ee.bytea(raw.single['ciphertext'] as String),
          isNot(containsAllInOrder('secret'.codeUnits)),
        );

        var bobView = await bobRepo.messages(dm);
        expect(bobView.single.body, 'hello bob, this is secret');
        expect(bobView.single.encrypted, isTrue);
        // Each MLS message decrypts once: a re-fetch must come from the cache.
        bobView = await bobRepo.messages(dm);
        expect(bobView.single.body, 'hello bob, this is secret');

        await bobRepo.acceptRequest(dm);
        await bobRepo.send(dm, 'hi alice');
        final aliceView = await aliceRepo.messages(dm);
        expect(
          aliceView.map((m) => m.body),
          ['hello bob, this is secret', 'hi alice'],
          reason: 'sender reads its own message from the cache, and the reply',
        );
        expect(aliceView.any((m) => m.unreadable), isFalse);

        // Plaintext can't be smuggled into the encrypted DM.
        await expectLater(
          alice.db.from('message').insert({
            'conversation_id': dm,
            'sender_id': alice.id,
            'body': 'clear',
          }),
          throwsA(isA<PostgrestException>()),
        );

        final list = await bobRepo.conversations();
        final summary = list.firstWhere((c) => c.id == dm);
        expect(summary.e2ee, isTrue);
        expect(summary.subtitle, 'Encrypted message');

        // ── encrypted group ──
        final group = await aliceRepo.createGroup('secret club', [bob.id]);
        expect(await aliceRepo.isEncrypted(group), isTrue);
        await bobRepo.acceptRequest(group);
        await bobRepo.send(group, 'group hello');
        expect((await aliceRepo.messages(group)).single.body, 'group hello');

        // ── fallback: carol has no MLS device, so the DM stays plaintext ──
        final plain = await aliceRepo.startDm(carol.id);
        expect(await aliceRepo.isEncrypted(plain), isFalse);
        await aliceRepo.send(plain, 'not encrypted');
        expect((await aliceRepo.messages(plain)).single.body, 'not encrypted');
      } finally {
        for (final id in created) {
          await admin.from('conversation').delete().eq('created_by', id);
          await admin.auth.admin.deleteUser(id);
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
