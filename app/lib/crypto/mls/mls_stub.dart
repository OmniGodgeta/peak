import 'dart:typed_data';

import 'mls_api.dart';

/// Web build: no native MLS yet (needs a WASM build of OpenMLS).
class MlsClient {
  MlsClient._();

  static bool available({String? libraryPath}) => false;

  static MlsClient create(Uint8List identity, {String? libraryPath}) =>
      throw MlsException('MLS is not available on this platform');

  static MlsClient load(Uint8List state, {String? libraryPath}) =>
      throw MlsException('MLS is not available on this platform');

  Uint8List save() => throw UnimplementedError();
  Uint8List keyPackage() => throw UnimplementedError();
  void createGroup(Uint8List groupId) => throw UnimplementedError();
  (Uint8List commit, Uint8List welcome) addMembers(
    Uint8List groupId,
    List<Uint8List> keyPackages,
  ) => throw UnimplementedError();
  Uint8List removeMembers(Uint8List groupId, List<Uint8List> identities) =>
      throw UnimplementedError();
  Uint8List join(Uint8List welcome) => throw UnimplementedError();
  Uint8List encrypt(Uint8List groupId, Uint8List plaintext) =>
      throw UnimplementedError();
  MlsProcessed process(Uint8List groupId, Uint8List message) =>
      throw UnimplementedError();
  int epoch(Uint8List groupId) => throw UnimplementedError();
  List<Uint8List> members(Uint8List groupId) => throw UnimplementedError();
  List<(Uint8List identity, Uint8List key)> memberKeys(Uint8List groupId) =>
      throw UnimplementedError();
  void dispose() {}
}
