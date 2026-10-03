import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Where an [OpenMlsE2ee] keeps its state blob between launches.
abstract interface class MlsStateStorage {
  Future<Uint8List?> read();
  Future<void> write(Uint8List state);
}

/// In-memory storage, for tests.
class MemoryMlsStateStorage implements MlsStateStorage {
  Uint8List? _state;
  @override
  Future<Uint8List?> read() async => _state;
  @override
  Future<void> write(Uint8List state) async => _state = state;
}

/// Where a device's MLS state lives between launches: a file in app support
/// storage, AES-256-GCM encrypted with a key kept in the platform keystore
/// (flutter_secure_storage). The state holds every group secret, so it
/// never touches disk in the clear. One file per signed-in account.
class MlsStateStore implements MlsStateStorage {
  MlsStateStore(this.accountId);
  final String accountId;

  static const _secure = FlutterSecureStorage();
  final _aes = AesGcm.with256bits();

  String get _keyName => 'peak.mls.$accountId.key';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/peak_mls_$accountId.bin');
  }

  Future<SecretKey> _key() async {
    final existing = await _secure.read(key: _keyName);
    if (existing != null) return SecretKey(base64Decode(existing));
    final k = await _aes.newSecretKey();
    await _secure.write(
      key: _keyName,
      value: base64Encode(await k.extractBytes()),
    );
    return k;
  }

  @override
  Future<Uint8List?> read() async {
    final f = await _file();
    if (!await f.exists()) return null;
    final box = SecretBox.fromConcatenation(
      await f.readAsBytes(),
      nonceLength: _aes.nonceLength,
      macLength: _aes.macAlgorithm.macLength,
    );
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: await _key()));
  }

  @override
  Future<void> write(Uint8List state) async {
    final box = await _aes.encrypt(state, secretKey: await _key());
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(box.concatenation(), flush: true);
    await tmp.rename(f.path); // atomic: never a half-written state
  }

  /// Forget this device's MLS identity (sign-out of a revoked device).
  Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
    await _secure.delete(key: _keyName);
  }
}
