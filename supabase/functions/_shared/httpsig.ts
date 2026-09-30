// HTTP Signatures as the fediverse uses them (draft-cavage-http-signatures,
// rsa-sha256 — what Mastodon, Pleroma, Misskey etc. send and require), plus
// the RFC 3230 Digest header. WebCrypto only.
//
// Signing string: one "name: value" line per listed header, lower-cased,
// with the pseudo-header "(request-target)" = "<method> <path+query>".

const enc = new TextEncoder();

export function b64(bytes: ArrayBuffer | Uint8Array): string {
  const u = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const x of u) s += String.fromCharCode(x);
  return btoa(s);
}

function unb64(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function pemBody(pem: string): Uint8Array<ArrayBuffer> {
  return unb64(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""));
}

export function importPublicPem(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "spki",
    pemBody(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
}

export function importPrivatePem(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "pkcs8",
    pemBody(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

function toPem(label: string, der: ArrayBuffer): string {
  const lines = b64(der).match(/.{1,64}/g) ?? [];
  return `-----BEGIN ${label}-----\n${
    lines.join("\n")
  }\n-----END ${label}-----\n`;
}

/** A fresh RSA-2048 key pair as PEM (Mastodon rejects EC keys). */
export async function generateActorKeys(): Promise<
  { publicPem: string; privatePem: string }
> {
  const kp = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  return {
    publicPem: toPem(
      "PUBLIC KEY",
      await crypto.subtle.exportKey("spki", kp.publicKey),
    ),
    privatePem: toPem(
      "PRIVATE KEY",
      await crypto.subtle.exportKey("pkcs8", kp.privateKey),
    ),
  };
}

export async function digestHeader(body: Uint8Array | string): Promise<string> {
  const bytes = typeof body === "string" ? enc.encode(body) : body;
  const h = await crypto.subtle.digest(
    "SHA-256",
    bytes as Uint8Array<ArrayBuffer>,
  );
  return `SHA-256=${b64(h)}`;
}

export function signingString(
  method: string,
  pathAndQuery: string,
  headerNames: string[],
  get: (name: string) => string | null,
): string {
  return headerNames.map((h) => {
    if (h === "(request-target)") {
      return `(request-target): ${method.toLowerCase()} ${pathAndQuery}`;
    }
    const v = get(h);
    if (v === null) throw new Error(`signed header missing: ${h}`);
    return `${h}: ${v}`;
  }).join("\n");
}

/**
 * Headers for a signed POST of [body] to [url] as [keyId]. Returns the
 * headers to send (Host, Date, Digest, Content-Type, Signature).
 */
export async function signedPostHeaders(
  url: URL,
  body: string,
  keyId: string,
  privatePem: string,
  now = new Date(),
): Promise<Record<string, string>> {
  const headers: Record<string, string> = {
    host: url.host,
    date: now.toUTCString(),
    digest: await digestHeader(body),
    "content-type": "application/activity+json",
  };
  const names = ["(request-target)", "host", "date", "digest", "content-type"];
  const str = signingString(
    "POST",
    url.pathname + url.search,
    names,
    (h) => headers[h] ?? null,
  );
  const key = await importPrivatePem(privatePem);
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    enc.encode(str),
  );
  headers.signature = `keyId="${keyId}",algorithm="rsa-sha256",headers="${
    names.join(" ")
  }",signature="${b64(sig)}"`;
  return headers;
}

/** Signed GET (for fetching actors from servers in "authorized fetch" mode). */
export async function signedGetHeaders(
  url: URL,
  keyId: string,
  privatePem: string,
  now = new Date(),
): Promise<Record<string, string>> {
  const headers: Record<string, string> = {
    host: url.host,
    date: now.toUTCString(),
    accept: "application/activity+json",
  };
  const names = ["(request-target)", "host", "date"];
  const str = signingString(
    "GET",
    url.pathname + url.search,
    names,
    (h) => headers[h] ?? null,
  );
  const key = await importPrivatePem(privatePem);
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    enc.encode(str),
  );
  headers.signature = `keyId="${keyId}",algorithm="rsa-sha256",headers="${
    names.join(" ")
  }",signature="${b64(sig)}"`;
  return headers;
}

export interface ParsedSignature {
  keyId: string;
  algorithm: string;
  headers: string[];
  signature: string;
}

export function parseSignature(header: string): ParsedSignature {
  const out: Record<string, string> = {};
  for (const m of header.matchAll(/(\w+)="([^"]*)"/g)) out[m[1]] = m[2];
  if (!out.keyId || !out.signature) {
    throw new Error("malformed Signature header");
  }
  return {
    keyId: out.keyId,
    algorithm: out.algorithm ?? "rsa-sha256",
    headers: (out.headers ?? "date").toLowerCase().split(/\s+/),
    signature: out.signature,
  };
}

export interface VerifyOptions {
  /** Max clock skew for the Date header. */
  maxSkewMs?: number;
  now?: Date;
}

/**
 * Verifies an incoming signed request. Requires (request-target), host,
 * date and — for bodies — digest to be signed, the Digest to match the body,
 * and the Date to be recent. [publicPem] is the key the caller looked up for
 * the parsed keyId. Throws with a reason on any failure.
 */
export async function verifyRequest(
  req: { method: string; url: string; headers: Headers },
  body: string,
  sig: ParsedSignature,
  publicPem: string,
  opts: VerifyOptions = {},
): Promise<void> {
  const alg = sig.algorithm.toLowerCase();
  if (alg !== "rsa-sha256" && alg !== "hs2019") {
    throw new Error(`unsupported algorithm ${sig.algorithm}`);
  }
  const needed = ["(request-target)", "host", "date"];
  if (req.method.toUpperCase() === "POST") needed.push("digest");
  for (const h of needed) {
    if (!sig.headers.includes(h)) throw new Error(`${h} must be signed`);
  }
  const date = Date.parse(req.headers.get("date") ?? "");
  const now = (opts.now ?? new Date()).getTime();
  if (
    !Number.isFinite(date) ||
    Math.abs(now - date) > (opts.maxSkewMs ?? 12 * 3600_000)
  ) {
    throw new Error("date too far from now");
  }
  if (req.method.toUpperCase() === "POST") {
    const got = req.headers.get("digest") ?? "";
    const want = await digestHeader(body);
    if (!got.split(",").map((s) => s.trim()).includes(want)) {
      throw new Error("digest mismatch");
    }
  }
  const u = new URL(req.url);
  const str = signingString(
    req.method,
    u.pathname + u.search,
    sig.headers,
    (h) =>
      h === "host" ? (req.headers.get("host") ?? u.host) : req.headers.get(h),
  );
  const key = await importPublicPem(publicPem);
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    unb64(sig.signature),
    enc.encode(str),
  );
  if (!ok) throw new Error("bad signature");
}
