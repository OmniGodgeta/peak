# lib/crypto

The encryption layer for Peak's messaging. Full design:
[`docs/ENCRYPTION.md`](../../../docs/ENCRYPTION.md).

## Status: Phase 2.5-2 (native MLS + device keys; conversations next)

- `e2ee_service.dart` — the interface the app talks to, and its provider.
- `noop_e2ee.dart` — the current transport-only behaviour, made explicit.

`e2eeServiceProvider` returns `NoopE2ee` today. Messaging is **not** end-to-end
encrypted yet; the UI must not claim otherwise while `E2eeService.available` is
false.

- `mls/` — `dart:ffi` bindings to `native/peak_mls` (OpenMLS), with a web
  stub; `mls_state_store.dart` keeps the device state encrypted on disk.
- `openmls_e2ee.dart` — the MLS implementation, chosen only when the build
  sets `PEAK_E2EE=mls` and `libpeak_mls.so` is packaged
  (`tool/build_mls.sh`). It manages the device identity and key-package
  pool; `createGroup` refuses until 2.5-3 wires conversations.
