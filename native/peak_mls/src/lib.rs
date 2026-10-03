//! Peak's MLS layer (docs/ENCRYPTION.md): OpenMLS behind a small, flat C ABI
//! that Dart calls through `dart:ffi` (app/lib/crypto/mls/mls_ffi.dart).
//!
//! One [`Client`] per device. Its whole state — signature key, key-package
//! secrets, every group's ratchet state — lives in an in-memory store that
//! the app saves (encrypted at rest on its side) with [`Client::save`] after
//! each operation and restores with [`Client::load`].
//!
//! Ciphersuite: MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519. Welcomes carry
//! the ratchet tree extension, so joiners need nothing out of band.

use openmls::prelude::{tls_codec::*, *};
use openmls_basic_credential::SignatureKeyPair;
use openmls_memory_storage::MemoryStorage;
use openmls_rust_crypto::RustCrypto;
use openmls_traits::OpenMlsProvider;

/// Epochs whose keys a device keeps after moving on, so a message sent just
/// before a membership change still decrypts after the device has processed
/// that change (OpenMLS keeps none by default).
pub const MAX_PAST_EPOCHS: usize = 5;

pub const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

const STATE_MAGIC: &[u8; 6] = b"PMLS1\n";

/// OpenMLS provider over a store we can serialise.
#[derive(Default)]
pub struct Provider {
    crypto: RustCrypto,
    storage: MemoryStorage,
}

impl OpenMlsProvider for Provider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = MemoryStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }
    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }
    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

/// What processing an incoming message produced.
#[derive(Debug, PartialEq, Eq)]
pub enum Processed {
    /// Decrypted application data.
    Application(Vec<u8>),
    /// A commit from someone else, now merged; the group moved to this epoch.
    Commit(u64),
    /// A proposal, stored until a commit references it.
    Proposal,
    /// One of our own messages coming back from the server; nothing to do.
    Own,
}

pub type Result<T> = std::result::Result<T, String>;

fn err<E: std::fmt::Debug>(what: &str) -> impl FnOnce(E) -> String + '_ {
    move |e| format!("{what}: {e:?}")
}

pub struct Client {
    provider: Provider,
    signer: SignatureKeyPair,
    identity: Vec<u8>,
}

impl Client {
    /// A new device. [identity] is the MLS BasicCredential identity —
    /// Peak uses `"<account_id>:<device_id>"`.
    pub fn new(identity: &[u8]) -> Result<Self> {
        let provider = Provider::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .map_err(err("signature key"))?;
        signer
            .store(provider.storage())
            .map_err(err("store signature key"))?;
        Ok(Self {
            provider,
            signer,
            identity: identity.to_vec(),
        })
    }

    /// Serialised device state (secret — the app encrypts it at rest).
    pub fn save(&self) -> Result<Vec<u8>> {
        let mut out = STATE_MAGIC.to_vec();
        let public = self.signer.public();
        for part in [self.identity.as_slice(), public] {
            out.extend_from_slice(&(part.len() as u32).to_be_bytes());
            out.extend_from_slice(part);
        }
        write_store(&self.provider.storage, &mut out)?;
        Ok(out)
    }

    pub fn load(state: &[u8]) -> Result<Self> {
        let rest = state
            .strip_prefix(STATE_MAGIC.as_slice())
            .ok_or("not a peak_mls state")?;
        let (identity, rest) = take_prefixed(rest)?;
        let (public, rest) = take_prefixed(rest)?;
        let storage = read_store(rest)?;
        let provider = Provider {
            crypto: RustCrypto::default(),
            storage,
        };
        let signer = SignatureKeyPair::read(
            provider.storage(),
            public,
            CIPHERSUITE.signature_algorithm(),
        )
        .ok_or("signature key missing from state")?;
        Ok(Self {
            provider,
            signer,
            identity: identity.to_vec(),
        })
    }

    pub fn identity(&self) -> &[u8] {
        &self.identity
    }

    fn credential(&self) -> CredentialWithKey {
        CredentialWithKey {
            credential: BasicCredential::new(self.identity.clone()).into(),
            signature_key: self.signer.public().into(),
        }
    }

    /// A fresh single-use KeyPackage for the server's pool. Its private part
    /// stays in this client's store until someone uses it to add us.
    pub fn key_package(&self) -> Result<Vec<u8>> {
        let bundle = KeyPackage::builder()
            .build(CIPHERSUITE, &self.provider, &self.signer, self.credential())
            .map_err(err("key package"))?;
        bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(err("serialise key package"))
    }

    fn group(&self, group_id: &[u8]) -> Result<MlsGroup> {
        MlsGroup::load(self.provider.storage(), &GroupId::from_slice(group_id))
            .map_err(err("load group"))?
            .ok_or_else(|| "unknown group".to_string())
    }

    /// Start a group (one per conversation; Peak uses the conversation id).
    pub fn create_group(&self, group_id: &[u8]) -> Result<()> {
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .max_past_epochs(MAX_PAST_EPOCHS)
            .build();
        MlsGroup::new_with_group_id(
            &self.provider,
            &self.signer,
            &config,
            GroupId::from_slice(group_id),
            self.credential(),
        )
        .map_err(err("create group"))?;
        Ok(())
    }

    /// Add devices by their KeyPackages. Returns (commit for the existing
    /// members, welcome for the new ones). Merged locally before returning.
    pub fn add_members(
        &self,
        group_id: &[u8],
        key_packages: &[Vec<u8>],
    ) -> Result<(Vec<u8>, Vec<u8>)> {
        let mut group = self.group(group_id)?;
        let mut kps = Vec::with_capacity(key_packages.len());
        for bytes in key_packages {
            let kp = KeyPackageIn::tls_deserialize(&mut bytes.as_slice())
                .map_err(err("parse key package"))?
                .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                .map_err(err("invalid key package"))?;
            kps.push(kp);
        }
        let (commit, welcome, _info) = group
            .add_members(&self.provider, &self.signer, &kps)
            .map_err(err("add members"))?;
        group
            .merge_pending_commit(&self.provider)
            .map_err(err("merge commit"))?;
        Ok((
            commit
                .tls_serialize_detached()
                .map_err(err("serialise commit"))?,
            welcome
                .tls_serialize_detached()
                .map_err(err("serialise welcome"))?,
        ))
    }

    /// Remove every device whose credential identity is in [identities].
    /// Returns the commit for the remaining members.
    pub fn remove_members(&self, group_id: &[u8], identities: &[Vec<u8>]) -> Result<Vec<u8>> {
        let mut group = self.group(group_id)?;
        let leaves: Vec<LeafNodeIndex> = group
            .members()
            .filter(|m| {
                identities
                    .iter()
                    .any(|id| m.credential.serialized_content() == id.as_slice())
            })
            .map(|m| m.index)
            .collect();
        if leaves.is_empty() {
            return Err("no such member".into());
        }
        let (commit, _welcome, _info) = group
            .remove_members(&self.provider, &self.signer, &leaves)
            .map_err(err("remove members"))?;
        group
            .merge_pending_commit(&self.provider)
            .map_err(err("merge commit"))?;
        commit
            .tls_serialize_detached()
            .map_err(err("serialise commit"))
    }

    /// Join from a Welcome addressed to one of our key packages. Returns the
    /// group id.
    pub fn join(&self, welcome: &[u8]) -> Result<Vec<u8>> {
        let msg = MlsMessageIn::tls_deserialize(&mut &welcome[..]).map_err(err("parse welcome"))?;
        let welcome = match msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err("not a welcome".into()),
        };
        let join_config = MlsGroupJoinConfig::builder()
            .use_ratchet_tree_extension(true)
            .max_past_epochs(MAX_PAST_EPOCHS)
            .build();
        let group = StagedWelcome::new_from_welcome(&self.provider, &join_config, welcome, None)
            .map_err(err("stage welcome"))?
            .into_group(&self.provider)
            .map_err(err("join group"))?;
        Ok(group.group_id().as_slice().to_vec())
    }

    pub fn encrypt(&self, group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
        let mut group = self.group(group_id)?;
        let msg = group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(err("encrypt"))?;
        msg.tls_serialize_detached()
            .map_err(err("serialise message"))
    }

    /// Process an incoming application message, commit or proposal.
    pub fn process(&self, group_id: &[u8], message: &[u8]) -> Result<Processed> {
        let mut group = self.group(group_id)?;
        let msg = MlsMessageIn::tls_deserialize(&mut &message[..]).map_err(err("parse message"))?;
        let protocol = msg
            .try_into_protocol_message()
            .map_err(err("not a group message"))?;
        let processed = group
            .process_message(&self.provider, protocol)
            .map_err(err("process"))?;
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app) => {
                Ok(Processed::Application(app.into_bytes()))
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                group
                    .merge_staged_commit(&self.provider, *staged)
                    .map_err(err("merge commit"))?;
                Ok(Processed::Commit(group.epoch().as_u64()))
            }
            ProcessedMessageContent::ProposalMessage(p) => {
                group
                    .store_pending_proposal(self.provider.storage(), *p)
                    .map_err(err("store proposal"))?;
                Ok(Processed::Proposal)
            }
            ProcessedMessageContent::ExternalJoinProposalMessage(_) => Ok(Processed::Proposal),
            _ => Ok(Processed::Own),
        }
    }

    pub fn epoch(&self, group_id: &[u8]) -> Result<u64> {
        Ok(self.group(group_id)?.epoch().as_u64())
    }

    /// Credential identities of everyone in the group (for safety numbers
    /// and the device list check).
    pub fn members(&self, group_id: &[u8]) -> Result<Vec<Vec<u8>>> {
        Ok(self
            .group(group_id)?
            .members()
            .map(|m| m.credential.serialized_content().to_vec())
            .collect())
    }
}

// The store's map is public; its own (de)serialiser is test-only, so the
// state format is ours: u64 count, then (u64 key len, u64 value len, key,
// value) per entry, all big-endian.
fn write_store(s: &MemoryStorage, out: &mut Vec<u8>) -> Result<()> {
    let values = s
        .values
        .read()
        .map_err(|_| "store lock poisoned".to_string())?;
    out.extend_from_slice(&(values.len() as u64).to_be_bytes());
    for (k, v) in values.iter() {
        out.extend_from_slice(&(k.len() as u64).to_be_bytes());
        out.extend_from_slice(&(v.len() as u64).to_be_bytes());
        out.extend_from_slice(k);
        out.extend_from_slice(v);
    }
    Ok(())
}

fn read_store(mut b: &[u8]) -> Result<MemoryStorage> {
    fn u64_at(b: &mut &[u8]) -> Result<usize> {
        if b.len() < 8 {
            return Err("truncated store".into());
        }
        let (n, rest) = b.split_at(8);
        *b = rest;
        usize::try_from(u64::from_be_bytes(n.try_into().unwrap()))
            .map_err(|_| "bad length".to_string())
    }
    let count = u64_at(&mut b)?;
    let mut map = std::collections::HashMap::with_capacity(count.min(1 << 16));
    for _ in 0..count {
        let kl = u64_at(&mut b)?;
        let vl = u64_at(&mut b)?;
        if b.len() < kl + vl {
            return Err("truncated store".into());
        }
        let (k, rest) = b.split_at(kl);
        let (v, rest) = rest.split_at(vl);
        map.insert(k.to_vec(), v.to_vec());
        b = rest;
    }
    if !b.is_empty() {
        return Err("trailing bytes in state".into());
    }
    Ok(MemoryStorage {
        values: std::sync::RwLock::new(map),
    })
}

fn take_prefixed(b: &[u8]) -> Result<(&[u8], &[u8])> {
    if b.len() < 4 {
        return Err("truncated state".into());
    }
    let n = u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize;
    if b.len() < 4 + n {
        return Err("truncated state".into());
    }
    Ok((&b[4..4 + n], &b[4 + n..]))
}

pub mod ffi;

#[cfg(test)]
mod tests;
