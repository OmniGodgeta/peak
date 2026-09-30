// Cross-checks encryptWebPush against an independent implementation:
// the http_ece npm package (used by the web-push library) decrypts it.
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { createECDH, randomBytes } from "node:crypto";
import ece from "npm:http_ece@1.2.0";
import { b64urlEncode, encryptWebPush } from "./webpush.ts";
import { isPrivateIp } from "./public_host.ts";

Deno.test("http_ece decrypts what encryptWebPush produces", async () => {
  const ua = createECDH("prime256v1");
  ua.generateKeys();
  const auth = randomBytes(16);
  const msg = JSON.stringify({
    t: "call",
    title: "Peak",
    body: "Incoming call",
  });

  const body = await encryptWebPush(
    new TextEncoder().encode(msg),
    b64urlEncode(new Uint8Array(ua.getPublicKey())),
    b64urlEncode(new Uint8Array(auth)),
  );
  const plain = ece.decrypt(Buffer.from(body), {
    version: "aes128gcm",
    privateKey: ua,
    authSecret: auth,
  });
  assertEquals(plain.toString("utf8"), msg);
});

Deno.test("each message uses a fresh salt and sender key", async () => {
  const ua = createECDH("prime256v1");
  ua.generateKeys();
  const k = b64urlEncode(new Uint8Array(ua.getPublicKey()));
  const a = b64urlEncode(new Uint8Array(randomBytes(16)));
  const x = await encryptWebPush(new Uint8Array([1]), k, a);
  const y = await encryptWebPush(new Uint8Array([1]), k, a);
  assertEquals(x.slice(0, 16).toString() === y.slice(0, 16).toString(), false);
});

Deno.test("rejects malformed subscription keys", async () => {
  await assertRejects(() =>
    encryptWebPush(new Uint8Array([1]), "AAAA", "AAAAAAAAAAAAAAAAAAAAAA")
  );
});

Deno.test("private ranges are blocked", () => {
  for (
    const ip of [
      "127.0.0.1",
      "10.1.2.3",
      "192.168.0.9",
      "172.20.0.1",
      "100.65.133.127",
      "169.254.169.254",
      "::1",
      "fd7a:115c::1",
      "::ffff:10.0.0.1",
    ]
  ) {
    assertEquals(isPrivateIp(ip), true, ip);
  }
  for (const ip of ["1.1.1.1", "159.203.1.2", "2606:4700::1111"]) {
    assertEquals(isPrivateIp(ip), false, ip);
  }
});
