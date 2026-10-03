//! The C ABI. Every function returns 0 on success and -1 on failure (see
//! `peak_mls_last_error`), never unwinds across the boundary (panics are
//! caught and reported as errors), and hands out buffers the caller frees
//! with `peak_mls_buf_free`. Clients are opaque pointers freed with
//! `peak_mls_client_free`.
//!
//! Byte arguments are (ptr, len). Lists of byte strings are passed as one
//! buffer of u32-big-endian-length-prefixed items.

#![allow(clippy::missing_safety_doc)]

use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::{Client, Processed, Result};

#[repr(C)]
pub struct PeakBuf {
    pub ptr: *mut u8,
    pub len: usize,
}

impl PeakBuf {
    fn from_vec(v: Vec<u8>) -> Self {
        let mut b = v.into_boxed_slice();
        let out = PeakBuf {
            ptr: b.as_mut_ptr(),
            len: b.len(),
        };
        std::mem::forget(b);
        out
    }
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_error(msg: String) {
    let c = CString::new(msg.replace('\0', " ")).unwrap_or_default();
    LAST_ERROR.with(|e| *e.borrow_mut() = c);
}

/// Runs [f], turning errors and panics into -1 + last error.
fn guard(f: impl FnOnce() -> Result<()>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            set_error(e);
            -1
        }
        Err(_) => {
            set_error("internal panic".into());
            -1
        }
    }
}

unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

unsafe fn client<'a>(c: *mut Client) -> Result<&'a Client> {
    c.as_ref().ok_or_else(|| "null client".to_string())
}

unsafe fn put(out: *mut PeakBuf, v: Vec<u8>) {
    if !out.is_null() {
        *out = PeakBuf::from_vec(v);
    }
}

fn split_prefixed(mut b: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut out = Vec::new();
    while !b.is_empty() {
        let (item, rest) = crate::take_prefixed(b)?;
        out.push(item.to_vec());
        b = rest;
    }
    Ok(out)
}

/// Human-readable message for the last -1 on this thread. Valid until the
/// next failing call on the same thread; do not free.
#[no_mangle]
pub extern "C" fn peak_mls_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_buf_free(buf: PeakBuf) {
    if !buf.ptr.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            buf.ptr, buf.len,
        )));
    }
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_client_new(
    id: *const u8,
    id_len: usize,
    out: *mut *mut Client,
) -> i32 {
    guard(|| {
        let c = Client::new(bytes(id, id_len))?;
        *out = Box::into_raw(Box::new(c));
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_client_load(
    state: *const u8,
    len: usize,
    out: *mut *mut Client,
) -> i32 {
    guard(|| {
        let c = Client::load(bytes(state, len))?;
        *out = Box::into_raw(Box::new(c));
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_client_free(c: *mut Client) {
    if !c.is_null() {
        drop(Box::from_raw(c));
    }
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_save(c: *mut Client, out: *mut PeakBuf) -> i32 {
    guard(|| {
        put(out, client(c)?.save()?);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_key_package(c: *mut Client, out: *mut PeakBuf) -> i32 {
    guard(|| {
        put(out, client(c)?.key_package()?);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_create_group(
    c: *mut Client,
    gid: *const u8,
    gid_len: usize,
) -> i32 {
    guard(|| client(c)?.create_group(bytes(gid, gid_len)))
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_add_members(
    c: *mut Client,
    gid: *const u8,
    gid_len: usize,
    kps: *const u8,
    kps_len: usize,
    commit_out: *mut PeakBuf,
    welcome_out: *mut PeakBuf,
) -> i32 {
    guard(|| {
        let list = split_prefixed(bytes(kps, kps_len))?;
        let (commit, welcome) = client(c)?.add_members(bytes(gid, gid_len), &list)?;
        put(commit_out, commit);
        put(welcome_out, welcome);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_remove_members(
    c: *mut Client,
    gid: *const u8,
    gid_len: usize,
    ids: *const u8,
    ids_len: usize,
    commit_out: *mut PeakBuf,
) -> i32 {
    guard(|| {
        let list = split_prefixed(bytes(ids, ids_len))?;
        put(
            commit_out,
            client(c)?.remove_members(bytes(gid, gid_len), &list)?,
        );
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_join(
    c: *mut Client,
    welcome: *const u8,
    len: usize,
    gid_out: *mut PeakBuf,
) -> i32 {
    guard(|| {
        put(gid_out, client(c)?.join(bytes(welcome, len))?);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn peak_mls_encrypt(
    c: *mut Client,
    gid: *const u8,
    gid_len: usize,
    pt: *const u8,
    pt_len: usize,
    out: *mut PeakBuf,
) -> i32 {
    guard(|| {
        put(
            out,
            client(c)?.encrypt(bytes(gid, gid_len), bytes(pt, pt_len))?,
        );
        Ok(())
    })
}

/// kind_out: 1 = application (out = plaintext), 2 = commit merged
/// (out empty; see peak_mls_epoch), 3 = proposal stored, 4 = our own
/// message echoed back (nothing to do).
#[no_mangle]
pub unsafe extern "C" fn peak_mls_process(
    c: *mut Client,
    gid: *const u8,
    gid_len: usize,
    msg: *const u8,
    msg_len: usize,
    kind_out: *mut i32,
    out: *mut PeakBuf,
) -> i32 {
    guard(|| {
        let (kind, data) = match client(c)?.process(bytes(gid, gid_len), bytes(msg, msg_len))? {
            Processed::Application(p) => (1, p),
            Processed::Commit(_) => (2, Vec::new()),
            Processed::Proposal => (3, Vec::new()),
            Processed::Own => (4, Vec::new()),
        };
        if !kind_out.is_null() {
            *kind_out = kind;
        }
        put(out, data);
        Ok(())
    })
}

/// The group's epoch, or -1 on error.
#[no_mangle]
pub unsafe extern "C" fn peak_mls_epoch(c: *mut Client, gid: *const u8, gid_len: usize) -> i64 {
    let mut e = -1i64;
    let rc = guard(|| {
        e = client(c)?.epoch(bytes(gid, gid_len))? as i64;
        Ok(())
    });
    if rc == 0 {
        e
    } else {
        -1
    }
}

/// Member identities, u32-BE length-prefixed, into out.
#[no_mangle]
pub unsafe extern "C" fn peak_mls_members(
    c: *mut Client,
    gid: *const u8,
    gid_len: usize,
    out: *mut PeakBuf,
) -> i32 {
    guard(|| {
        let mut buf = Vec::new();
        for m in client(c)?.members(bytes(gid, gid_len))? {
            buf.extend_from_slice(&(m.len() as u32).to_be_bytes());
            buf.extend_from_slice(&m);
        }
        put(out, buf);
        Ok(())
    })
}

/// Member (identity, signature key) pairs, flattened: identity, key,
/// identity, key, ... each u32-BE length-prefixed, into out.
#[no_mangle]
pub unsafe extern "C" fn peak_mls_member_keys(
    c: *mut Client,
    gid: *const u8,
    gid_len: usize,
    out: *mut PeakBuf,
) -> i32 {
    guard(|| {
        let mut buf = Vec::new();
        for (id, key) in client(c)?.member_keys(bytes(gid, gid_len))? {
            for part in [id, key] {
                buf.extend_from_slice(&(part.len() as u32).to_be_bytes());
                buf.extend_from_slice(&part);
            }
        }
        put(out, buf);
        Ok(())
    })
}
