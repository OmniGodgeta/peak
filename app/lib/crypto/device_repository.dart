import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/supabase_providers.dart';

/// One of the account owner's app installs, as seen by the Devices screen.
class PeakDevice {
  const PeakDevice({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.lastSeenAt,
    required this.revokedAt,
    required this.unclaimedPackages,
  });

  final String id;
  final String? label;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final DateTime? revokedAt;

  /// Size of this device's pre-published KeyPackage pool. Stays 0 until the
  /// MLS build (Phase 2.5-3) starts generating real KeyPackages.
  final int unclaimedPackages;

  bool get isRevoked => revokedAt != null;

  factory PeakDevice.fromMap(Map<String, dynamic> m) => PeakDevice(
    id: m['id'] as String,
    label: m['label'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    lastSeenAt: DateTime.parse(m['last_seen_at'] as String),
    revokedAt: m['revoked_at'] == null
        ? null
        : DateTime.parse(m['revoked_at'] as String),
    unclaimedPackages: (m['unclaimed_packages'] as int?) ?? 0,
  );
}

/// Manages this install's long-lived device identity (an Ed25519 signature
/// keypair held in the platform keystore) and the account's device roster.
///
/// The signature key is generated here in pure Dart so device identity exists
/// from first launch — before the native OpenMLS lib (Phase 2.5-1) is wired.
/// When MLS content encryption lands (2.5-3) this same key becomes the device's
/// MLS credential signing key; since no encrypted conversations exist yet, it
/// can be rotated for free if the crypto provider needs a different format.
class DeviceRepository {
  DeviceRepository(this._db);

  final SupabaseClient _db;
  final FlutterSecureStorage _store = const FlutterSecureStorage();
  final Ed25519 _sig = Ed25519();

  String? _deviceId;

  /// The server id of *this* install, once [ensureRegistered] has run.
  String? get thisDeviceId => _deviceId;

  String _key(String suffix) {
    final uid = _db.auth.currentUser!.id;
    return 'peak.device.$uid.$suffix';
  }

  /// Load-or-create the local keypair, then register (or re-attach) this
  /// install server-side. Safe to call on every launch — it's idempotent and
  /// also refreshes `last_seen_at`.
  Future<String> ensureRegistered() async {
    final knownId = await _store.read(key: _key('id'));

    var seedB64 = await _store.read(key: _key('seed'));
    String pubHex;
    if (seedB64 == null) {
      final pair = await _sig.newKeyPair();
      final seed = await pair.extractPrivateKeyBytes();
      final pub = await pair.extractPublicKey();
      seedB64 = base64Encode(seed);
      pubHex = _hex(pub.bytes);
      await _store.write(key: _key('seed'), value: seedB64);
      await _store.write(key: _key('pub'), value: pubHex);
    } else {
      pubHex = (await _store.read(key: _key('pub')))!;
    }

    final id = await _db.rpc(
      'register_device',
      params: {
        'p_public_sig_key': pubHex,
        // Only name the device on first registration; never clobber a
        // label the user set later.
        'p_label': knownId == null ? _defaultLabel() : null,
      },
    ) as String;

    await _store.write(key: _key('id'), value: id);
    _deviceId = id;
    return id;
  }

  Future<List<PeakDevice>> myDevices() async {
    final rows = await _db.rpc('my_devices') as List;
    return [
      for (final r in rows) PeakDevice.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<void> rename(String deviceId, String label) => _db.rpc(
    'rename_device',
    params: {'p_device_id': deviceId, 'p_label': label},
  );

  /// Revoke a device. Revoking *this* device also clears its local identity —
  /// the caller should sign the session out afterwards.
  Future<void> revoke(String deviceId) async {
    await _db.rpc('revoke_device', params: {'p_device_id': deviceId});
    if (deviceId == _deviceId) {
      await _store.delete(key: _key('id'));
      await _store.delete(key: _key('seed'));
      await _store.delete(key: _key('pub'));
      _deviceId = null;
    }
  }

  static String _hex(List<int> bytes) {
    final b = StringBuffer();
    for (final x in bytes) {
      b.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  static String _defaultLabel() {
    if (kIsWeb) return 'Web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android device',
      TargetPlatform.iOS => 'iPhone / iPad',
      TargetPlatform.macOS => 'Mac',
      TargetPlatform.windows => 'Windows PC',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
  }
}

final deviceRepositoryProvider = Provider<DeviceRepository>((ref) {
  return DeviceRepository(ref.watch(supabaseProvider));
});

/// Registers this install on first read, then exposes the device roster.
/// Watched by the Devices screen; kicked off at app start by [PeakApp].
final myDevicesProvider = FutureProvider<List<PeakDevice>>((ref) async {
  final repo = ref.watch(deviceRepositoryProvider);
  await repo.ensureRegistered();
  return repo.myDevices();
});
