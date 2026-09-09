# lib/crypto

The encryption layer for Peak's messaging. Full design:
[`docs/ENCRYPTION.md`](../../../docs/ENCRYPTION.md).

## Status: Phase 2.5-0 (seam only)

- `e2ee_service.dart` — the interface the app talks to, and its provider.
- `noop_e2ee.dart` — the current transport-only behaviour, made explicit.

`e2eeServiceProvider` returns `NoopE2ee` today. Messaging is **not** end-to-end
encrypted yet; the UI must not claim otherwise while `E2eeService.available` is
false.

## Coming

- `mls/mls_ffi.dart` — `dart:ffi` bindings to the OpenMLS native lib
- `mls/openmls_e2ee.dart` — the real implementation
- `device_keys.dart` — device signature keygen + secure-enclave storage

The native lib (OpenMLS, Rust → static lib via cargo-ndk / xcframework) is set
up with infra/ops — it needs NDK/CMake config in `android/` and a pod for iOS.
