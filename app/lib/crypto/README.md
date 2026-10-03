# lib/crypto

The encryption layer for Peak's messaging. Full design:
[`docs/ENCRYPTION.md`](../../../docs/ENCRYPTION.md).

## Status: Phase 2.5-3 (encrypted conversations, behind `PEAK_E2EE=mls`)

- `e2ee_service.dart` — the interface the app talks to, and its provider.
- `noop_e2ee.dart` — the current transport-only behaviour, made explicit.

`e2eeServiceProvider` returns `NoopE2ee` unless the build sets
`PEAK_E2EE=mls` (release builds don't yet). The chat screen shows a lock only
for conversations whose `conversation.e2ee` is true.

- `mls/` — `dart:ffi` bindings to `native/peak_mls` (OpenMLS), with a web
  stub; `mls_state_store.dart` keeps the device state encrypted on disk.
- `openmls_e2ee.dart` — the MLS implementation, chosen only when the build
  sets `PEAK_E2EE=mls` and `libpeak_mls.so` is packaged
  (`tool/build_mls.sh`). It manages the device identity and key-package
  pool, sets up encrypted conversations, encrypts/decrypts messages, and
  caches plaintexts (MLS decrypts each message only once).
  `MessagingRepository` goes through it for every send and read.
- Two-device test against the local stack:
  `app/test/e2ee_conversation_local_test.dart` (opt-in, see its header).
