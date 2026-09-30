import 'dart:typed_data';

/// What processing an incoming group message produced.
sealed class MlsProcessed {
  const MlsProcessed();
}

class MlsApplication extends MlsProcessed {
  const MlsApplication(this.plaintext);
  final Uint8List plaintext;
}

/// Someone else's commit, merged: the group moved to a new epoch.
class MlsCommit extends MlsProcessed {
  const MlsCommit();
}

class MlsProposal extends MlsProcessed {
  const MlsProposal();
}

/// One of our own messages echoed back by the server.
class MlsOwn extends MlsProcessed {
  const MlsOwn();
}

class MlsException implements Exception {
  MlsException(this.message);
  final String message;
  @override
  String toString() => 'MlsException: $message';
}

/// u32-big-endian length-prefixed concatenation (the native list format).
Uint8List mlsPackList(List<Uint8List> items) {
  final b = BytesBuilder(copy: false);
  for (final i in items) {
    b.add((ByteData(4)..setUint32(0, i.length)).buffer.asUint8List());
    b.add(i);
  }
  return b.toBytes();
}

List<Uint8List> mlsUnpackList(Uint8List bytes) {
  final out = <Uint8List>[];
  var o = 0;
  final view = ByteData.sublistView(bytes);
  while (o + 4 <= bytes.length) {
    final n = view.getUint32(o);
    o += 4;
    if (o + n > bytes.length) throw MlsException('truncated list');
    out.add(Uint8List.sublistView(bytes, o, o + n));
    o += n;
  }
  return out;
}
