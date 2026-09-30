// Web Push message encryption (RFC 8291, "aes128gcm" content coding from
// RFC 8188), using only WebCrypto so it runs unchanged in the Supabase edge
// runtime. The push distributor (ntfy, NextPush, ...) only ever sees
// ciphertext; the phone's UnifiedPush connector decrypts it.

const enc = new TextEncoder();

// ArrayBuffer-backed bytes, the only kind WebCrypto's typings accept.
type Bytes = Uint8Array<ArrayBuffer>;

export function b64urlDecode(s: string): Bytes {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const bin = atob((s + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export function b64urlEncode(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function concat(...parts: Uint8Array[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

async function hkdf(
  salt: Bytes,
  ikm: Bytes,
  info: Bytes,
  bytes: number,
): Promise<Bytes> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, [
    "deriveBits",
  ]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt, info },
    key,
    bytes * 8,
  );
  return new Uint8Array(bits);
}

export interface EncryptOptions {
  /** Fixed values for tests only. */
  salt?: Bytes;
  senderKeys?: CryptoKeyPair;
}

/**
 * Encrypts [plaintext] for a subscription's `p256dh` public key and `auth`
 * secret (both base64url, as the client reports them). Returns the request
 * body to POST with `Content-Encoding: aes128gcm`.
 */
export async function encryptWebPush(
  plaintext: Uint8Array,
  p256dh: string,
  authSecret: string,
  opts: EncryptOptions = {},
): Promise<Bytes> {
  const uaPublic = b64urlDecode(p256dh);
  const auth = b64urlDecode(authSecret);
  if (uaPublic.length !== 65 || uaPublic[0] !== 0x04) {
    throw new Error("p256dh must be an uncompressed P-256 point");
  }
  if (auth.length !== 16) throw new Error("auth secret must be 16 bytes");

  const uaKey = await crypto.subtle.importKey(
    "raw",
    uaPublic,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const sender = opts.senderKeys ?? await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  ) as CryptoKeyPair;
  const asPublic = new Uint8Array(
    await crypto.subtle.exportKey("raw", sender.publicKey),
  );
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "ECDH", public: uaKey },
      sender.privateKey,
      256,
    ),
  );

  // RFC 8291 §3.4: combine the ECDH secret with the auth secret.
  const keyInfo = concat(enc.encode("WebPush: info\0"), uaPublic, asPublic);
  const ikm = await hkdf(auth, shared, keyInfo, 32);

  // RFC 8188 §2.2 / §2.3: content-encryption key and nonce.
  const salt = opts.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(
    salt,
    ikm,
    enc.encode("Content-Encoding: aes128gcm\0"),
    16,
  );
  const nonce = await hkdf(
    salt,
    ikm,
    enc.encode("Content-Encoding: nonce\0"),
    12,
  );

  // One record: plaintext, then the 0x02 "last record" delimiter.
  const record = concat(plaintext, new Uint8Array([2]));
  const rs = 4096;
  if (record.length + 16 > rs) throw new Error("push payload too large");
  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, [
    "encrypt",
  ]);
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, aes, record),
  );

  const header = new Uint8Array(16 + 4 + 1 + asPublic.length);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, rs);
  header[20] = asPublic.length;
  header.set(asPublic, 21);
  return concat(header, ciphertext);
}
