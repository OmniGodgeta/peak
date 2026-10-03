# End-to-end encryption (Phase 2.5)

Peak's DMs and group chats become end-to-end encrypted: the server relays and
stores **ciphertext only** and never holds a key that can read message content.
Multi-device is in scope from the start — phone + tablet + web at once, with
history available on new devices.

Status: **2.5-1, 2.5-2 and 2.5-3 done.** With the `PEAK_E2EE=mls` build flag,
new DMs and groups are end-to-end encrypted when every member has an MLS
device; otherwise they stay transport-only. Release builds don't set the flag
yet, so nobody gets encrypted chats until it's flipped (after a real
two-phone check, and 2.5-4 so members can be added).

---

## 1. Protocol: MLS (RFC 9420)

We use **Messaging Layer Security** via **OpenMLS** (Rust), compiled to a native
library and called over FFI from Flutter.

Why MLS over the Signal protocol:

- **Groups scale.** MLS is O(log n) for group key updates via its ratchet tree;
  Signal's Double Ratchet is pairwise and needs sender-key workarounds that get
  awkward past a handful of members.
- **Multi-device is native.** Each *device* is its own MLS group member (an MLS
  "leaf"). A user with three devices contributes three leaves. Adding or removing
  a device is a normal MLS Add/Remove — no special-casing.
- **It's a standard.** RFC 9420, with formal analysis and multiple
  interoperable implementations.
- **Post-compromise security.** A compromised device's access is healed on the
  next key update it isn't part of.

Ciphersuite: `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` to start (widely
supported, no exotic curves). Revisit for PQ hybrids later.

---

## 2. Identity & devices

| Concept | Where |
|---|---|
| **Account** | `profile` (unchanged) |
| **Device** | A single app install. Has a long-lived **device signature key** (Ed25519) generated on-device, private part in the secure enclave, never leaves. |
| **Key packages** | Pre-published, single-use MLS `KeyPackage`s per device, so others can add the device to a group without it being online. The server holds a pool per device and hands them out one at a time. |
| **Credential** | An MLS `BasicCredential` binding the device key to `"<account_id>:<device_id>"`. Phase 5's proof-of-personhood can later upgrade this to a signed credential. |

Device lifecycle:

1. **Register** — on first launch after login, the device generates its
   signature key, uploads the public key + an initial batch of key packages.
2. **Replenish** — the client tops up its key-package pool whenever it drops
   below a threshold.
3. **Revoke** — user removes a device from account settings → server deletes its
   key packages and every MLS group the device is in issues a Remove.
4. **Rotate** — device keys rotate on a schedule and on suspicion.

The server **must not** be trusted to report the device list honestly (it could
add a rogue device). Mitigations: a **device-list transparency log** the client
checks, and a **safety-number / key-verification** screen per conversation (like
Signal's) that hashes all participating device keys.

---

## 3. Conversation = one MLS group

Each `conversation` maps to exactly one MLS group.

- **Creation** — the creator's device fetches a key package for every device of
  every member, builds the MLS group, and sends the resulting Welcome messages
  (via the server) to each added device.
- **Sending** — the sending device encrypts the plaintext to the current group
  epoch, producing an MLS `PrivateMessage`. The server stores the ciphertext
  blob and relays it.
- **Membership change** — adding a person adds all their devices (Add + Commit);
  removing does the reverse. A new device of an existing member is also just an
  Add.
- **Epoch** — every Commit advances the group epoch; `message` rows carry the
  epoch they were encrypted in so a client knows which key to use.

The server sees: who is in a conversation, message timing and size, epoch
numbers, and ciphertext. It does **not** see message content, and cannot derive
group keys.

---

## 4. Multi-device & history

A new device added to an existing MLS group can decrypt messages **from its join
epoch onward** — MLS does not back-fill. To give the user their history on a new
device we add an **encrypted history archive**:

- Each device, as it reads messages, appends `{message_id, plaintext,
  metadata}` to a local log and periodically encrypts a batch under a
  **per-account history key** and uploads the blob to storage
  (`chat-history` bucket, private).
- The per-account history key is derived from a **recovery secret** the user
  holds — shown once at setup as a recovery phrase, and optionally escrowed to
  the user's own cloud (never to Peak) à la Signal's SVR-style design is out of
  scope; we start with "write down your phrase."
- A new device, after joining the MLS group, prompts for the recovery phrase,
  pulls the archive blobs, and decrypts them locally.
- No phrase → the new device simply starts with no history. Nothing is lost on
  other devices.

This keeps the server unable to read history while making multi-device usable.

---

## 5. Schema (this migration)

New tables (all RLS-gated; content columns hold only ciphertext / public keys):

- `device` — `id`, `account_id`, `public_sig_key`, `label`, `created_at`,
  `last_seen_at`, `revoked_at`.
- `key_package` — `id`, `device_id`, `data` (opaque MLS KeyPackage bytes),
  `consumed_at`. Single-use; a `claim_key_packages(account_ids[])` RPC hands out
  one unconsumed package per device.
- `mls_group_state` — `conversation_id`, `epoch`, `ciphersuite`,
  `public_group_state` (opaque), updated on each Commit.
- `mls_message` — `id`, `conversation_id`, `sender_device_id`, `epoch`,
  `content_type` (`application` | `commit` | `proposal` | `welcome`),
  `ciphertext`, `created_at`. Replaces plaintext `message.body` for E2E
  conversations; `message` keeps the row for ordering, reactions, and the
  tombstone, with `body` empty.
- `history_blob` — `account_id`, `seq`, `ciphertext`, `created_at`.

`message.body` / `message_media` stay for the transport-only conversations that
predate the cutover and for any future opt-out group (e.g. a public
announcement channel).

---

## 6. Client architecture

```
lib/crypto/
  e2ee_service.dart        abstract API the app talks to
  mls/
    mls_ffi.dart           dart:ffi bindings to the native lib
    openmls_e2ee.dart      real implementation
  noop_e2ee.dart           transport-only fallback (current default)
  device_keys.dart         keygen + secure-enclave storage
```

`MessagingRepository` is refactored so every send/receive goes through
`E2eeService`. Today it resolves to `NoopE2ee` (plaintext, matches Phase 2).
When the native lib is wired and the flag is on, it resolves to `OpenMlsE2ee`.

Secure storage: device signature private key + MLS key store in
`flutter_secure_storage` (Keychain / Android Keystore). The MLS state store is
an encrypted SQLite DB (SQLCipher via `sqlcipher_flutter_libs`) keyed by a value
in the enclave.

---

## 7. Rollout stages

- [x] **2.5-0** — this doc + schema (`device`, `key_package`, `mls_*`,
      `history_blob`) + `E2eeService` seam with the no-op impl.
- [x] **2.5-1** — `native/peak_mls` (OpenMLS 0.9, Rust) behind a flat C ABI
      (every call panic-guarded, errors via `peak_mls_last_error`);
      `tool/build_mls.sh` builds `libpeak_mls.so` for arm64-v8a /
      armeabi-v7a / x86_64 (cargo-ndk; outputs gitignored) and the host;
      `app/lib/crypto/mls/` has the `dart:ffi` bindings (web gets a stub).
      Verified: 7 Rust tests (two-way messaging, restart via save/load, a
      third device joining + commits, a removed device locked out, errors not
      panics, single-use key packages), a Dart→native round-trip test, and an
      on-device integration test on the Android emulator. iOS (xcframework)
      and web (WASM) builds are not done.
- [x] **2.5-2** — device registration + key-package pool + device-list UI.
      Every install registers a `device`; Settings → Devices lists / renames
      / revokes. With `PEAK_E2EE=mls`, `OpenMlsE2ee` gives the device an MLS
      identity (`<account>:<device>`), keeps its state AES-256-GCM encrypted
      on disk (key in the platform keystore), and tops the server pool up to
      20 real KeyPackages whenever it drops below 10.
- [x] **2.5-3** — encrypted conversations (`20261016000000_e2ee_conversations`).
      A new DM/group whose members all have an MLS device gets an MLS group
      (id = conversation id): the creating device claims it
      (`begin_conversation_e2ee`), adds every device of every member, leaves a
      Welcome per device in `mls_message`, then `enable_conversation_e2ee`.
      Messages keep their `message` row (order, replies, reactions, read
      state, tombstones) with `body` empty and the MLS ciphertext in
      `message.ciphertext` (+ `mls_epoch`). Other devices join from their
      Welcome on first read/send. MLS decrypts a message once and a sender
      can't decrypt its own, so plaintexts are cached on-device inside the
      same AES-GCM-encrypted file as the MLS state (one atomic write).
      Server guards: no plaintext into an encrypted conversation, no
      ciphertext into a plaintext one, no attachments, edits, or new members
      in encrypted ones yet (the UI hides those). Verified: pgTAP
      `40_e2ee_conversations` (13), and `app/test/e2ee_conversation_local_test.dart`
      — two devices with real OpenMLS against the local stack: encrypted DM
      both ways (server holds no plaintext), re-fetch from cache, encrypted
      group, plaintext fallback for a member without an MLS device.
      **Not yet verified on two real phones.** Encrypted attachments are a
      follow-up; message reports from encrypted chats carry no content.
- [ ] **2.5-4** — membership/device changes (Add/Remove/Update + Commit),
      epoch handling, key rotation schedule.
- [ ] **2.5-5** — encrypted history archive + new-device restore + recovery
      phrase UI.
- [ ] **2.5-6** — key-verification / safety-number screen; device-list
      transparency check.
- [ ] **2.5-7** — migrate remaining transport-only DMs (or leave them, clearly
      labelled) and flip the default.

## 8. Threat model summary

Protected against: a fully malicious server (reads nothing, forges nothing that
clients accept), network attackers, and compromise of an old device (healed).

Not protected against (documented limitations): a compromised *current* device
of a participant; traffic-analysis metadata (who talks to whom, when, how much)
— minimised, not eliminated; a user who loses their recovery phrase loses
history on new devices only.
