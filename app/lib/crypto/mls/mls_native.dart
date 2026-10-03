import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'mls_api.dart';

final class _Buf extends Struct {
  external Pointer<Uint8> ptr;
  @Size()
  external int len;
}

typedef _NewN = Int32 Function(Pointer<Uint8>, Size, Pointer<Pointer<Void>>);
typedef _NewD = int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>);
typedef _FreeN = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);
typedef _BufFreeN = Void Function(_Buf);
typedef _BufFreeD = void Function(_Buf);
typedef _ErrN = Pointer<Utf8> Function();
typedef _OutN = Int32 Function(Pointer<Void>, Pointer<_Buf>);
typedef _OutD = int Function(Pointer<Void>, Pointer<_Buf>);
typedef _GidN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _GidD = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _GidOutN = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Size,
  Pointer<_Buf>,
);
typedef _GidOutD = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<_Buf>,
);
typedef _Gid2OutN = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<_Buf>,
);
typedef _Gid2OutD = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<_Buf>,
);
typedef _AddN = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<_Buf>,
  Pointer<_Buf>,
);
typedef _AddD = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<_Buf>,
  Pointer<_Buf>,
);
typedef _ProcN = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Size,
  Pointer<Int32>,
  Pointer<_Buf>,
);
typedef _ProcD = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int32>,
  Pointer<_Buf>,
);
typedef _EpochN = Int64 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _EpochD = int Function(Pointer<Void>, Pointer<Uint8>, int);

class _Lib {
  _Lib(DynamicLibrary l)
    : clientNew = l.lookupFunction<_NewN, _NewD>('peak_mls_client_new'),
      clientLoad = l.lookupFunction<_NewN, _NewD>('peak_mls_client_load'),
      clientFree = l.lookupFunction<_FreeN, _FreeD>('peak_mls_client_free'),
      bufFree = l.lookupFunction<_BufFreeN, _BufFreeD>('peak_mls_buf_free'),
      lastError = l.lookupFunction<_ErrN, _ErrN>('peak_mls_last_error'),
      save = l.lookupFunction<_OutN, _OutD>('peak_mls_save'),
      keyPackage = l.lookupFunction<_OutN, _OutD>('peak_mls_key_package'),
      createGroup = l.lookupFunction<_GidN, _GidD>('peak_mls_create_group'),
      addMembers = l.lookupFunction<_AddN, _AddD>('peak_mls_add_members'),
      removeMembers = l.lookupFunction<_Gid2OutN, _Gid2OutD>(
        'peak_mls_remove_members',
      ),
      join = l.lookupFunction<_GidOutN, _GidOutD>('peak_mls_join'),
      encrypt = l.lookupFunction<_Gid2OutN, _Gid2OutD>('peak_mls_encrypt'),
      process = l.lookupFunction<_ProcN, _ProcD>('peak_mls_process'),
      epoch = l.lookupFunction<_EpochN, _EpochD>('peak_mls_epoch'),
      members = l.lookupFunction<_GidOutN, _GidOutD>('peak_mls_members'),
      memberKeys = l.lookupFunction<_GidOutN, _GidOutD>('peak_mls_member_keys');

  final _NewD clientNew, clientLoad;
  final _FreeD clientFree;
  final _BufFreeD bufFree;
  final _ErrN lastError;
  final _OutD save, keyPackage;
  final _GidD createGroup;
  final _AddD addMembers;
  final _Gid2OutD removeMembers, encrypt;
  final _GidOutD join, members, memberKeys;
  final _ProcD process;
  final _EpochD epoch;

  static final _cache = <String, _Lib?>{};

  static _Lib? open(String? path) {
    final p = path ?? 'libpeak_mls.so';
    return _cache.putIfAbsent(p, () {
      try {
        return _Lib(DynamicLibrary.open(p));
      } on ArgumentError {
        return null;
      }
    });
  }
}

/// One device's MLS state (native OpenMLS). Not thread-safe; use from one
/// isolate. Call [dispose] when done; [save] after every change and store
/// the bytes encrypted.
class MlsClient {
  MlsClient._(this._lib, this._handle);
  final _Lib _lib;
  Pointer<Void> _handle;

  /// Whether the native library is present in this build.
  static bool available({String? libraryPath}) =>
      _Lib.open(libraryPath) != null;

  static _Lib _need(String? path) =>
      _Lib.open(path) ?? (throw MlsException('native MLS library not found'));

  static MlsClient create(Uint8List identity, {String? libraryPath}) {
    final lib = _need(libraryPath);
    return using((a) {
      final out = a<Pointer<Void>>();
      final id = _copy(a, identity);
      _check(lib, lib.clientNew(id, identity.length, out));
      return MlsClient._(lib, out.value);
    });
  }

  static MlsClient load(Uint8List state, {String? libraryPath}) {
    final lib = _need(libraryPath);
    return using((a) {
      final out = a<Pointer<Void>>();
      _check(lib, lib.clientLoad(_copy(a, state), state.length, out));
      return MlsClient._(lib, out.value);
    });
  }

  static Pointer<Uint8> _copy(Allocator a, Uint8List b) {
    final p = a<Uint8>(b.isEmpty ? 1 : b.length);
    p.asTypedList(b.length).setAll(0, b);
    return p;
  }

  static void _check(_Lib lib, int rc) {
    if (rc != 0) throw MlsException(lib.lastError().toDartString());
  }

  Uint8List _take(Pointer<_Buf> buf) {
    final b = buf.ref;
    final out = b.ptr == nullptr
        ? Uint8List(0)
        : Uint8List.fromList(b.ptr.asTypedList(b.len));
    _lib.bufFree(b);
    return out;
  }

  Pointer<Void> get _h =>
      _handle == nullptr ? throw StateError('MlsClient disposed') : _handle;

  Uint8List save() => using((a) {
    final out = a<_Buf>();
    _check(_lib, _lib.save(_h, out));
    return _take(out);
  });

  Uint8List keyPackage() => using((a) {
    final out = a<_Buf>();
    _check(_lib, _lib.keyPackage(_h, out));
    return _take(out);
  });

  void createGroup(Uint8List groupId) => using((a) {
    _check(_lib, _lib.createGroup(_h, _copy(a, groupId), groupId.length));
  });

  (Uint8List commit, Uint8List welcome) addMembers(
    Uint8List groupId,
    List<Uint8List> keyPackages,
  ) => using((a) {
    final list = mlsPackList(keyPackages);
    final commit = a<_Buf>(), welcome = a<_Buf>();
    _check(
      _lib,
      _lib.addMembers(
        _h,
        _copy(a, groupId),
        groupId.length,
        _copy(a, list),
        list.length,
        commit,
        welcome,
      ),
    );
    return (_take(commit), _take(welcome));
  });

  Uint8List removeMembers(Uint8List groupId, List<Uint8List> identities) =>
      using((a) {
        final list = mlsPackList(identities);
        final out = a<_Buf>();
        _check(
          _lib,
          _lib.removeMembers(
            _h,
            _copy(a, groupId),
            groupId.length,
            _copy(a, list),
            list.length,
            out,
          ),
        );
        return _take(out);
      });

  /// Joins from a Welcome; returns the group id.
  Uint8List join(Uint8List welcome) => using((a) {
    final out = a<_Buf>();
    _check(_lib, _lib.join(_h, _copy(a, welcome), welcome.length, out));
    return _take(out);
  });

  Uint8List encrypt(Uint8List groupId, Uint8List plaintext) => using((a) {
    final out = a<_Buf>();
    _check(
      _lib,
      _lib.encrypt(
        _h,
        _copy(a, groupId),
        groupId.length,
        _copy(a, plaintext),
        plaintext.length,
        out,
      ),
    );
    return _take(out);
  });

  MlsProcessed process(Uint8List groupId, Uint8List message) => using((a) {
    final kind = a<Int32>(), out = a<_Buf>();
    _check(
      _lib,
      _lib.process(
        _h,
        _copy(a, groupId),
        groupId.length,
        _copy(a, message),
        message.length,
        kind,
        out,
      ),
    );
    final data = _take(out);
    return switch (kind.value) {
      1 => MlsApplication(data),
      2 => const MlsCommit(),
      3 => const MlsProposal(),
      _ => const MlsOwn(),
    };
  });

  int epoch(Uint8List groupId) => using((a) {
    final e = _lib.epoch(_h, _copy(a, groupId), groupId.length);
    if (e < 0) throw MlsException(_lib.lastError().toDartString());
    return e;
  });

  List<Uint8List> members(Uint8List groupId) => using((a) {
    final out = a<_Buf>();
    _check(_lib, _lib.members(_h, _copy(a, groupId), groupId.length, out));
    return mlsUnpackList(_take(out));
  });

  /// (identity, signature public key) of every member — what a safety
  /// number commits to.
  List<(Uint8List identity, Uint8List key)> memberKeys(Uint8List groupId) =>
      using((a) {
        final out = a<_Buf>();
        _check(
          _lib,
          _lib.memberKeys(_h, _copy(a, groupId), groupId.length, out),
        );
        final flat = mlsUnpackList(_take(out));
        return [
          for (var i = 0; i + 1 < flat.length; i += 2) (flat[i], flat[i + 1]),
        ];
      });

  void dispose() {
    if (_handle != nullptr) {
      _lib.clientFree(_handle);
      _handle = nullptr;
    }
  }
}
