import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'device_repository.dart';
import 'e2ee_service.dart';
import 'mls/mls.dart';
import 'mls/mls_state_store.dart';

/// The MLS implementation (docs/ENCRYPTION.md), over the native OpenMLS
/// library. Active only when the build sets PEAK_E2EE=mls and the library
/// is packaged (tool/build_mls.sh); otherwise [NoopE2ee] stays in charge.
///
/// - Device identity `<account>:<device>`, KeyPackage pool topped up (2.5-2).
/// - Encrypted conversations (2.5-3): one MLS group per conversation, group
///   id = the conversation id. The creating device adds every device of every
///   member and leaves each a Welcome in `mls_message`; the others join from
///   it the first time they read or send.
/// - MLS can decrypt a message only once and a sender can't decrypt its own,
///   so plaintexts are cached here, saved in the same encrypted blob as the
///   MLS state (one atomic write, so a crash can't lose a decrypted message).
class OpenMlsE2ee implements E2eeService {
  OpenMlsE2ee(
    this._db,
    this._devices, {
    MlsStateStorage Function(String accountId)? storage,
    this.libraryPath,
  }) : _storageFor = storage ?? MlsStateStore.new;

  final SupabaseClient _db;
  final DeviceRegistrar _devices;
  final MlsStateStorage Function(String accountId) _storageFor;

  /// Native library override (host tests); null = the packaged one.
  final String? libraryPath;

  MlsClient? _client;
  MlsStateStorage? _store;
  Map<String, String> _plain = {};
  Future<void> _tail = Future.value();

  static const _poolTarget = 20;
  static const _poolLow = 10;
  static const ciphersuite = 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519';
  static const _magic = [0x50, 0x4b, 0x4d, 0x32]; // "PKM2"

  @override
  bool get available => true;

  /// Runs [op] after every earlier operation: the MLS state is one mutable
  /// object, and two concurrent decrypts of one message would burn its key.
  Future<T> _locked<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<MlsClient> _open() async {
    final existing = _client;
    if (existing != null) return existing;
    final uid = _db.auth.currentUser!.id;
    final deviceId = _devices.thisDeviceId ?? await _devices.ensureRegistered();
    final store = _store = _storageFor(uid);
    final blob = await store.read();
    MlsClient client;
    if (blob == null) {
      client = MlsClient.create(
        _utf8('$uid:$deviceId'),
        libraryPath: libraryPath,
      );
      _plain = {};
      _client = client;
      await _persist();
    } else {
      final (state, plain) = _unpack(blob);
      client = MlsClient.load(state, libraryPath: libraryPath);
      _plain = plain;
      _client = client;
    }
    return client;
  }

  /// Drop the in-memory state so the next call reloads what was last saved
  /// (used to back out of a half-finished group setup).
  void _discardUnsaved() {
    _client?.dispose();
    _client = null;
  }

  Future<void> _persist() async =>
      _store!.write(_pack(_client!.save(), _plain));

  @override
  Future<void> ensureDeviceRegistered() => _locked(() async {
    final client = await _open();
    final deviceId = _devices.thisDeviceId!;
    final pool = (await _db.rpc(
      'key_package_pool',
      params: {'p_device_id': deviceId},
    ) as num).toInt();
    if (pool >= _poolLow) return;
    final fresh = [
      for (var i = pool; i < _poolTarget; i++) _hex(client.keyPackage()),
    ];
    // The private halves are in the state now; save before the server can
    // hand the public halves out.
    await _persist();
    await _db.rpc(
      'publish_key_packages',
      params: {'p_device_id': deviceId, 'p_packages': fresh},
    );
  });

  @override
  Future<bool> setUpConversation(
    String conversationId,
    List<String> otherMemberIds,
  ) => _locked(() async {
    final client = await _open();
    final me = _db.auth.currentUser!.id;
    final thisDevice = _devices.thisDeviceId!;

    // One KeyPackage per device of every member, my other devices included.
    final rows = await _db.rpc(
      'claim_key_packages',
      params: {
        'p_accounts': {...otherMemberIds, me}.toList(),
      },
    ) as List;
    final packages = <({String device, String account, Uint8List kp})>[
      for (final r in rows.cast<Map<String, dynamic>>())
        if (r['out_device_id'] != thisDevice)
          (
            device: r['out_device_id'] as String,
            account: r['out_account_id'] as String,
            kp: _unhex(r['out_key_package'] as String),
          ),
    ];
    final covered = packages.map((p) => p.account).toSet();
    // Someone without an encryption-capable device would be locked out.
    if (otherMemberIds.any((id) => !covered.contains(id))) return false;

    final claimed = await _db.rpc(
      'begin_conversation_e2ee',
      params: {
        'p_conversation': conversationId,
        'p_ciphersuite': ciphersuite,
        'p_epoch': 1,
      },
    ) as bool;
    if (!claimed) return false;

    final gid = _utf8(conversationId);
    try {
      client.createGroup(gid);
      final (_, welcome) = client.addMembers(gid, [
        for (final p in packages) p.kp,
      ]);
      final epoch = client.epoch(gid);
      await _db.from('mls_message').insert([
        for (final p in packages)
          {
            'conversation_id': conversationId,
            'sender_device_id': thisDevice,
            'recipient_device_id': p.device,
            'epoch': epoch,
            'content_type': 'welcome',
            'ciphertext': _bytea(welcome),
          },
      ]);
      await _persist();
    } catch (_) {
      _discardUnsaved();
      rethrow;
    }
    return await _db.rpc(
      'enable_conversation_e2ee',
      params: {'p_conversation': conversationId},
    ) as bool;
  });

  /// Make sure this device is in the conversation's group, joining from its
  /// Welcome if it hasn't yet. False if there's no Welcome for this device.
  Future<bool> _ensureJoined(MlsClient client, String conversationId) async {
    final gid = _utf8(conversationId);
    if (_hasGroup(client, gid)) return true;
    final rows = await _db
        .from('mls_message')
        .select('ciphertext')
        .eq('conversation_id', conversationId)
        .eq('content_type', 'welcome')
        .eq('recipient_device_id', _devices.thisDeviceId!)
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return false;
    client.join(_unhex(rows.first['ciphertext'] as String));
    await _persist();
    return true;
  }

  static bool _hasGroup(MlsClient client, Uint8List gid) {
    try {
      client.epoch(gid);
      return true;
    } on MlsException {
      return false;
    }
  }

  /// Apply other devices' commits in epoch order (2.5-4). Our own commits
  /// were merged when we made them, so they're below our epoch already.
  Future<void> _catchUp(MlsClient client, String conversationId) async {
    final gid = _utf8(conversationId);
    final rows = await _db
        .from('mls_message')
        .select('epoch, ciphertext')
        .eq('conversation_id', conversationId)
        .eq('content_type', 'commit')
        .gte('epoch', client.epoch(gid))
        .order('epoch');
    var changed = false;
    for (final r in rows) {
      if ((r['epoch'] as num).toInt() != client.epoch(gid)) continue;
      try {
        client.process(gid, _unhex(r['ciphertext'] as String));
      } on MlsException {
        break; // e.g. the commit removed this device; nothing further applies
      }
      changed = true;
    }
    if (changed) await _persist();
  }

  /// Publish a commit made at [epoch]; on a lost race, throw away the local
  /// merge (reload the last saved state) so the caller can catch up and retry.
  Future<bool> _publish(
    String conversationId,
    int epoch,
    Uint8List commit, {
    List<({String device, Uint8List welcome})> welcomes = const [],
    String? addMember,
  }) async {
    final ok = await _db.rpc(
      'publish_mls_commit',
      params: {
        'p_conversation': conversationId,
        'p_device': _devices.thisDeviceId!,
        'p_epoch': epoch,
        'p_commit': _bytea(commit),
        'p_welcomes': [
          for (final w in welcomes)
            {'device': w.device, 'welcome': _hex(w.welcome)},
        ],
        'p_add_member': ?addMember,
      },
    ) as bool;
    if (ok) {
      await _persist();
    } else {
      _discardUnsaved();
    }
    return ok;
  }

  /// One sync pass under the lock; false means a commit race was lost and
  /// the pass should be retried from fresh state.
  Future<bool> _syncOnce(String conversationId) async {
    final client = await _open();
    if (!await _ensureJoined(client, conversationId)) return true;
    await _catchUp(client, conversationId);
    final gid = _utf8(conversationId);
    final me = _devices.thisDeviceId!;

    final wanted = <String>{
      for (final r in (await _db.rpc(
        'conversation_devices',
        params: {'p_conversation': conversationId},
      ) as List).cast<Map<String, dynamic>>())
        r['device_id'] as String,
    };
    if (!wanted.contains(me)) return true; // we've left / been revoked
    final inGroup = <String, Uint8List>{
      for (final id in client.members(gid)) utf8.decode(id).split(':').last: id,
    };

    final remove = [
      for (final e in inGroup.entries)
        if (e.key != me && !wanted.contains(e.key)) e.value,
    ];
    if (remove.isNotEmpty) {
      final epoch = client.epoch(gid);
      final commit = client.removeMembers(gid, remove);
      if (!await _publish(conversationId, epoch, commit)) return false;
    }

    final add = wanted.where((d) => !inGroup.containsKey(d)).toList();
    if (add.isNotEmpty) {
      final rows = (await _db.rpc(
        'claim_device_key_packages',
        params: {'p_devices': add},
      ) as List).cast<Map<String, dynamic>>();
      if (rows.isNotEmpty) {
        final c = await _open();
        final epoch = c.epoch(gid);
        final (commit, welcome) = c.addMembers(gid, [
          for (final r in rows) _unhex(r['out_key_package'] as String),
        ]);
        if (!await _publish(
          conversationId,
          epoch,
          commit,
          welcomes: [
            for (final r in rows)
              (device: r['out_device_id'] as String, welcome: welcome),
          ],
        )) {
          return false;
        }
      }
    }
    return true;
  }

  @override
  Future<void> syncConversation(String conversationId) => _locked(() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await _syncOnce(conversationId)) return;
    }
  });

  @override
  Future<void> addMember(String conversationId, String userId) =>
      _locked(() async {
        for (var attempt = 0; attempt < 3; attempt++) {
          final client = await _open();
          if (!await _ensureJoined(client, conversationId)) {
            throw StateError('This device isn\'t part of this encrypted chat.');
          }
          await _catchUp(client, conversationId);
          final rows = (await _db.rpc(
            'claim_key_packages',
            params: {
              'p_accounts': [userId],
            },
          ) as List).cast<Map<String, dynamic>>();
          if (rows.isEmpty) {
            throw StateError(
              'They have no device that supports encrypted chats yet.',
            );
          }
          final gid = _utf8(conversationId);
          final epoch = client.epoch(gid);
          final (commit, welcome) = client.addMembers(gid, [
            for (final r in rows) _unhex(r['out_key_package'] as String),
          ]);
          if (await _publish(
            conversationId,
            epoch,
            commit,
            welcomes: [
              for (final r in rows)
                (device: r['out_device_id'] as String, welcome: welcome),
            ],
            addMember: userId,
          )) {
            return;
          }
        }
        throw StateError('The group kept changing; try again.');
      });

  @override
  Future<({Uint8List ciphertext, int epoch})> encryptMessage(
    String conversationId,
    String text,
  ) => _locked(() async {
    // Add/remove devices first, so a new device can read this message and
    // a removed one can't.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await _syncOnce(conversationId)) break;
    }
    final client = await _open();
    if (!await _ensureJoined(client, conversationId)) {
      throw StateError('This device isn\'t part of this encrypted chat.');
    }
    final gid = _utf8(conversationId);
    final ct = client.encrypt(gid, _utf8(text));
    await _persist();
    return (ciphertext: ct, epoch: client.epoch(gid));
  });

  @override
  Future<void> rememberSent(String messageId, String text) => _locked(() async {
    await _open();
    _plain[messageId] = text;
    await _persist();
  });

  @override
  Future<String?> readMessage(
    String conversationId,
    String messageId,
    Uint8List ciphertext,
  ) => _locked(() async {
    final client = await _open();
    final cached = _plain[messageId];
    if (cached != null) return cached;
    if (!await _ensureJoined(client, conversationId)) return null;
    final MlsProcessed r;
    try {
      r = client.process(_utf8(conversationId), ciphertext);
    } on MlsException {
      return null; // from before this device joined, or already consumed
    }
    if (r is! MlsApplication) return null;
    final text = utf8.decode(r.plaintext, allowMalformed: true);
    _plain[messageId] = text;
    await _persist();
    return text;
  });

  // ── encoding helpers ──────────────────────────────────────────────────────

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// A bytea column value for PostgREST: `\x` + hex.
  static String _bytea(Uint8List b) => '\\x${_hex(b)}';

  static Uint8List _unhex(String s) {
    final h = s.startsWith('\\x') ? s.substring(2) : s;
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// bytea column value (`\x…` from PostgREST) to bytes.
  static Uint8List bytea(String s) => _unhex(s);

  /// "PKM2" + u32 state length + MLS state + JSON {message id: plaintext}.
  static Uint8List _pack(Uint8List state, Map<String, String> plain) {
    final json = utf8.encode(jsonEncode(plain));
    final b = BytesBuilder(copy: false)
      ..add(_magic)
      ..add((ByteData(4)..setUint32(0, state.length)).buffer.asUint8List())
      ..add(state)
      ..add(json);
    return b.toBytes();
  }

  static (Uint8List, Map<String, String>) _unpack(Uint8List blob) {
    final isV2 =
        blob.length >= 8 &&
        List.generate(4, (i) => blob[i]).join(',') == _magic.join(',');
    if (!isV2) return (blob, {}); // 2.5-2 files: the bare MLS state
    final n = ByteData.sublistView(blob, 4, 8).getUint32(0);
    final state = Uint8List.sublistView(blob, 8, 8 + n);
    final plain = (jsonDecode(utf8.decode(blob.sublist(8 + n))) as Map)
        .cast<String, String>();
    return (state, plain);
  }
}
