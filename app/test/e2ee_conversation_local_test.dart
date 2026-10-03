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

/// Throwaway accounts and devices for the membership test (2.5-4).
class _Harness {
  _Harness(this.url, this.anon, String service, this.lib)
    : admin = SupabaseClient(url, service);
  final String url, anon, lib;
  final SupabaseClient admin;
  final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final created = <String>[];

  Future<String> account(String name) async {
    final u = await admin.auth.admin.createUser(
      AdminUserAttributes(
        email: 'e2e-$name-$tag@test.peak',
        password: 'pw-$tag',
        emailConfirm: true,
      ),
    );
    created.add(u.user!.id);
    final db = await _signIn(name);
    await db.rpc(
      'bootstrap_account',
      params: {
        'p_handle': 'e2e$name$tag',
        'p_display_name': name,
        'p_birthdate': '1990-01-01',
      },
    );
    return u.user!.id;
  }

  Future<SupabaseClient> _signIn(String name) async {
    final db = SupabaseClient(url, anon);
    await db.auth.signInWithPassword(
      email: 'e2e-$name-$tag@test.peak',
      password: 'pw-$tag',
    );
    return db;
  }

  /// A new device (its own session, MLS state and KeyPackages) for [name].
  Future<({MessagingRepository repo, SupabaseClient db, _TestDevice dev})>
  device(String name) async {
    final db = await _signIn(name);
    final dev = _TestDevice(db);
    final e2ee = OpenMlsE2ee(
      db,
      dev,
      storage: (_) => MemoryMlsStateStorage(),
      libraryPath: lib,
    );
    await e2ee.ensureDeviceRegistered();
    return (repo: MessagingRepository(db, e2ee), db: db, dev: dev);
  }

  Future<void> cleanUp() async {
    for (final id in created) {
      await admin.from('conversation').delete().eq('created_by', id);
      await admin.auth.admin.deleteUser(id);
    }
  }
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

  test(
    'membership changes: new device, added member, leaver, revoked device',
    () async {
      final h = _Harness(
        url,
        env['SUPABASE_ANON']!,
        env['SUPABASE_SERVICE']!,
        lib,
      );
      Future<List<String>> bodies(MessagingRepository r, String c) async => [
        for (final m in await r.messages(c)) m.unreadable ? '?' : m.body,
      ];
      try {
        await h.account('alice');
        final bob = await h.account('bob');
        final dave = await h.account('dave');
        final alicePhoneD = await h.device('alice');
        final alicePhone = alicePhoneD.repo;
        final bobPhoneD = await h.device('bob');
        final bobPhone = bobPhoneD.repo;

        final group = await alicePhone.createGroup('club', [bob]);
        expect(await alicePhone.isEncrypted(group), isTrue);
        await bobPhone.acceptRequest(group);
        await alicePhone.send(group, 'one');
        expect(await bodies(bobPhone, group), ['one']);

        // Alice signs in on a tablet after the group exists. The next send
        // from any member adds the tablet; it reads from then on, and can't
        // read what came before.
        final aliceTabletD = await h.device('alice');
        final aliceTablet = aliceTabletD.repo;
        await bobPhone.send(group, 'two');
        expect(await bodies(aliceTablet, group), [
          '?',
          'two',
        ], reason: 'new device joins; earlier messages stay unreadable');
        expect(await bodies(alicePhone, group), ['one', 'two']);

        // Adding a person to an encrypted group: all their devices join and
        // they become a member in one step.
        final davePhoneD = await h.device('dave');
        final davePhone = davePhoneD.repo;
        await alicePhone.addGroupMember(group, dave);
        await davePhone.acceptRequest(group);
        await alicePhone.send(group, 'three');
        expect(await bodies(davePhone, group), [
          '?',
          '?',
          'three',
        ], reason: 'a new member reads from joining on (history is 2.5-5)');
        expect(await bodies(bobPhone, group), [
          'one',
          'two',
          'three',
        ], reason: 'existing members follow the commit');
        await davePhone.send(group, 'four');
        expect((await bodies(aliceTablet, group)).last, 'four');

        // Bob leaves: the next sender removes his device from the MLS group.
        await bobPhone.leaveConversation(group);
        await alicePhone.send(group, 'five');
        final roster = await h.admin
            .from('mls_message')
            .select('content_type')
            .eq('conversation_id', group)
            .eq('content_type', 'commit');
        expect(
          roster.length,
          greaterThanOrEqualTo(3),
          reason: 'tablet add, dave add, bob removal',
        );
        expect((await bodies(davePhone, group)).last, 'five');

        // Alice revokes her tablet: removed on the next send, and the
        // remaining devices keep talking.
        await h.admin
            .from('device')
            .update({'revoked_at': DateTime.now().toIso8601String()})
            .eq('id', aliceTabletD.dev.thisDeviceId!);
        await davePhone.send(group, 'six');
        expect((await bodies(alicePhone, group)).last, 'six');

        final commits = await h.admin
            .from('mls_message')
            .select('id')
            .eq('conversation_id', group)
            .eq('content_type', 'commit');
        expect(
          commits.length,
          4,
          reason: 'tablet added, dave added, bob removed, tablet removed',
        );
        // Bob's device is out of the MLS group: his old state can't read
        // anything sent after the removal.
        expect(
          (await bobPhone.messages(group)),
          isEmpty,
          reason: 'he left: RLS hides the conversation from him entirely',
        );

        // Concurrent changes can't fork the group: a stale commit is refused.
        final state = await h.admin
            .from('mls_group_state')
            .select('epoch')
            .eq('conversation_id', group)
            .single();
        final stale = await alicePhoneD.db.rpc(
          'publish_mls_commit',
          params: {
            'p_conversation': group,
            'p_device': alicePhoneD.dev.thisDeviceId,
            'p_epoch': (state['epoch'] as num).toInt() - 1,
            'p_commit': '\\x00',
          },
        );
        expect(stale, isFalse);
      } finally {
        await h.cleanUp();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
