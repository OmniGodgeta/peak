// Round-trips our signer through our verifier, and cross-checks the RSA
// part with node:crypto (an independent implementation) over the same
// signing string Mastodon builds.
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { createVerify } from "node:crypto";
import {
  digestHeader,
  generateActorKeys,
  parseSignature,
  signedPostHeaders,
  signingString,
  verifyRequest,
} from "./httpsig.ts";

const keys = await generateActorKeys();
const url = new URL("https://remote.example/users/ada/inbox");
const body = JSON.stringify({
  type: "Follow",
  actor: "https://peak.example/users/bo",
});

async function signed(b = body, when = new Date()) {
  const h = await signedPostHeaders(
    url,
    b,
    "https://peak.example/users/bo#main-key",
    keys.privatePem,
    when,
  );
  return { method: "POST", url: url.toString(), headers: new Headers(h) };
}

Deno.test("a request we sign verifies", async () => {
  const req = await signed();
  await verifyRequest(
    req,
    body,
    parseSignature(req.headers.get("signature")!),
    keys.publicPem,
  );
});

Deno.test("node:crypto agrees with the signature over Mastodon's signing string", async () => {
  const req = await signed();
  const sig = parseSignature(req.headers.get("signature")!);
  const str = [
    "(request-target): post /users/ada/inbox",
    `host: remote.example`,
    `date: ${req.headers.get("date")}`,
    `digest: ${req.headers.get("digest")}`,
    `content-type: application/activity+json`,
  ].join("\n");
  assertEquals(
    str,
    signingString(
      "POST",
      "/users/ada/inbox",
      sig.headers,
      (h) => req.headers.get(h),
    ),
  );
  const v = createVerify("RSA-SHA256");
  v.update(str);
  assertEquals(v.verify(keys.publicPem, sig.signature, "base64"), true);
});

Deno.test("a tampered body fails the digest", async () => {
  const req = await signed();
  await assertRejects(
    () =>
      verifyRequest(
        req,
        body + " ",
        parseSignature(req.headers.get("signature")!),
        keys.publicPem,
      ),
    Error,
    "digest mismatch",
  );
});

Deno.test("a different key fails", async () => {
  const other = await generateActorKeys();
  const req = await signed();
  await assertRejects(
    () =>
      verifyRequest(
        req,
        body,
        parseSignature(req.headers.get("signature")!),
        other.publicPem,
      ),
    Error,
    "bad signature",
  );
});

Deno.test("stale dates are refused", async () => {
  const req = await signed(body, new Date(Date.now() - 24 * 3600_000));
  await assertRejects(
    () =>
      verifyRequest(
        req,
        body,
        parseSignature(req.headers.get("signature")!),
        keys.publicPem,
      ),
    Error,
    "date too far",
  );
});

Deno.test("unsigned digest is refused on POST", async () => {
  const req = await signed();
  const sig = parseSignature(req.headers.get("signature")!);
  sig.headers = sig.headers.filter((h) => h !== "digest");
  await assertRejects(
    () => verifyRequest(req, body, sig, keys.publicPem),
    Error,
    "digest must be signed",
  );
});

Deno.test("digest format", async () => {
  assertEquals(
    await digestHeader(""),
    "SHA-256=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=",
  );
});
