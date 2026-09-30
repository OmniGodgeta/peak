/// Peak's MLS (RFC 9420) layer — see docs/ENCRYPTION.md. On Android (and
/// desktop test hosts) it's the native OpenMLS library over dart:ffi; on
/// web there's no native code yet, so [MlsClient.available] is false.
library;

export 'mls_api.dart';
export 'mls_native.dart' if (dart.library.js_interop) 'mls_stub.dart';
