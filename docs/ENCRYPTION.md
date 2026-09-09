# End-to-end encryption (Phase 2.5)

Peak's DMs and group chats become end-to-end encrypted: the server relays and
stores **ciphertext only** and never holds a key that can read message content.
Multi-device is in scope from the start — phone + tablet + web at once, with
history available on new devices.

Status: **design + schema landed; native crypto integration is the next
milestone.** Messaging currently runs in the transport-only Phase 2 mode; the
switch to E2E is staged (see §7) and gated behind a feature flag until every
piece is in place.

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
- [ ] **2.5-1** — native build: OpenMLS → static lib for android
      (cargo-ndk + CMake) and iOS (xcframework); `dart:ffi` bindings; a smoke
      test that generates a keypair and round-trips a message locally.
      *(needs the Rust toolchain + native config — coordinate with infra/ops.)*
- [~] **2.5-2** — device registration + key-package pool + device-list UI.
      *Done:* every install registers a `device` with a pure-Dart Ed25519
      signature key; Settings → Devices lists / renames / revokes them
      (`register_device`, `my_devices`, `rename_device`, `revoke_device`).
      *Waiting on 2.5-1:* real KeyPackage generation — `publish_key_packages`
      / `key_package_pool` plumbing is in place but the pool stays empty until
      the native lib can mint KeyPackages.
- [ ] **2.5-3** — MLS group per new conversation; encrypt/decrypt application
      messages; server relays `mls_message` blobs; feature flag on for new
      conversations.
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
