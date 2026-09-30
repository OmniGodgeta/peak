import { assertEquals } from "jsr:@std/assert@1";
import {
  actorDoc,
  AS_PUBLIC,
  create,
  Fed,
  htmlToText,
  idOf,
  noteDoc,
  textToHtml,
  webfinger,
} from "./activitypub.ts";

const f = new Fed("https://peak.example/");

Deno.test("addresses", () => {
  assertEquals(f.domain, "peak.example");
  assertEquals(f.actor("ada"), "https://peak.example/users/ada");
  const id = "11111111-2222-3333-4444-555555555555";
  assertEquals(f.localPostId(f.note(id)), id);
  assertEquals(f.localPostId(`https://evil.example/posts/${id}`), null);
  assertEquals(f.localHandle("https://peak.example/users/ada"), "ada");
  assertEquals(f.localHandle("https://peak.example/users/ada/inbox"), null);
  assertEquals(f.localHandle("https://evil.example/users/ada"), null);
});

Deno.test("webfinger", () => {
  const w = webfinger(f, "ada");
  assertEquals(w.subject, "acct:ada@peak.example");
  assertEquals(w.links[0].href, "https://peak.example/users/ada");
});

Deno.test("actor carries its key and shared inbox", () => {
  const a = actorDoc(f, {
    handle: "ada",
    displayName: "Ada",
    bio: "<b>hi</b>",
    avatarUrl: null,
    publicKeyPem: "PEM",
    alsoKnownAs: [],
    movedTo: null,
    createdAt: "2026-01-01T00:00:00Z",
  });
  assertEquals(a.publicKey.id, "https://peak.example/users/ada#main-key");
  assertEquals(a.endpoints.sharedInbox, "https://peak.example/inbox");
  assertEquals(a.summary, "<p>&lt;b&gt;hi&lt;/b&gt;</p>");
});

Deno.test("public notes address the public and followers, escape text", () => {
  const n = noteDoc(f, {
    id: "11111111-2222-3333-4444-555555555555",
    authorHandle: "ada",
    body: "a < b\nline2\n\npara",
    title: null,
    contentWarning: "cw",
    createdAt: "t",
    replyToLocalId: null,
    replyToUri: "https://m.example/notes/1",
    attachments: [],
  });
  assertEquals(n.to, [AS_PUBLIC]);
  assertEquals(n.cc, ["https://peak.example/users/ada/followers"]);
  assertEquals(n.content, "<p>a &lt; b<br>line2</p><p>para</p>");
  assertEquals(n.inReplyTo, "https://m.example/notes/1");
  assertEquals(n.sensitive, true);
  const c = create(f, {
    id: "x",
    authorHandle: "ada",
    body: "b",
    title: null,
    contentWarning: null,
    createdAt: "t",
    replyToLocalId: null,
    replyToUri: null,
    attachments: [],
  });
  assertEquals(c.type, "Create");
  assertEquals(c.actor, "https://peak.example/users/ada");
});

Deno.test("remote HTML becomes inert plain text", () => {
  assertEquals(
    htmlToText(
      '<p>Hi <a href="x" onclick="evil()">@bo</a></p><p>two<br>lines &amp; &#x1F600;</p><script>alert(1)</script>',
    ),
    "Hi @bo\n\ntwo\nlines & 😀",
  );
  assertEquals(htmlToText("<img src=x onerror=alert(1)>"), "");
  assertEquals(htmlToText("a".repeat(10), 5), "aaaaa…");
  assertEquals(
    textToHtml(htmlToText("<p>x &lt;y&gt;</p>")),
    "<p>x &lt;y&gt;</p>",
  );
});

Deno.test("idOf", () => {
  assertEquals(idOf("a"), "a");
  assertEquals(idOf({ id: "b" }), "b");
  assertEquals(idOf([{ id: "c" }]), "c");
  assertEquals(idOf(null), null);
});
