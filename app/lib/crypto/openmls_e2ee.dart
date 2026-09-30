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
/// Done: device identity (`<account>:<device>`), state persisted encrypted,
/// KeyPackage pool kept topped up on the server (2.5-2), and per-group
/// encrypt/decrypt for groups this device is in. Not yet: creating and
/// joining groups for real conversations and relaying MLS messages
/// (2.5-3) — [createGroup] refuses until then, so nothing claims E2EE.
class OpenMlsE2ee implements E2eeService {
  OpenMlsE2ee(this._db, this._devices);

  final SupabaseClient _db;
  final DeviceRepository _devices;
  MlsClient? _client;
  MlsStateStore? _store;

  static const _poolTarget = 20;
  static const _poolLow = 10;

  @override
  bool get available => true;

  Future<MlsClient> _open() async {
    final existing = _client;
    if (existing != null) return existing;
    final uid = _db.auth.currentUser!.id;
    final deviceId = await _devices.ensureRegistered();
    final store = _store = MlsStateStore(uid);
    final saved = await store.read();
    final client = saved != null
        ? MlsClient.load(saved)
        : MlsClient.create(Uint8List.fromList(utf8.encode('$uid:$deviceId')));
    if (saved == null) await store.write(client.save());
    return _client = client;
  }

  Future<void> _persist() async => _store?.write(_client!.save());

  @override
  Future<void> ensureDeviceRegistered() async {
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
  }

  @override
  Future<void> createGroup(
    String conversationId,
    List<String> memberAccountIds,
  ) {
    throw UnsupportedError(
      'Encrypted conversations are the next stage (2.5-3); '
      'this build only prepares device keys.',
    );
  }

  @override
  Future<Uint8List> encrypt(String conversationId, Uint8List plaintext) async {
    final c = await _open();
    final out = c.encrypt(
      Uint8List.fromList(utf8.encode(conversationId)),
      plaintext,
    );
    await _persist();
    return out;
  }

  @override
  Future<Uint8List> decrypt(String conversationId, Uint8List ciphertext) async {
    final c = await _open();
    final r = c.process(
      Uint8List.fromList(utf8.encode(conversationId)),
      ciphertext,
    );
    await _persist();
    if (r is MlsApplication) return r.plaintext;
    throw StateError('not an application message');
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
