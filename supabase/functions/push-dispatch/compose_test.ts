import { assertEquals } from "jsr:@std/assert@1";
import { composeBundle, composeRing } from "./compose.ts";

Deno.test("single notices name the actor", () => {
  const p = composeBundle({ n: 1, kinds: ["reply"], last_kind: "reply", last_actor: "Ada", last_ref: "p1" });
  assertEquals(p, { t: "notice", title: "Peak", body: "Ada replied to you", ref: "p1" });
});

Deno.test("messages route to messages", () => {
  const p = composeBundle({ n: 1, kinds: ["message"], last_kind: "message", last_actor: "Ada", last_ref: "c1" });
  assertEquals(p.t, "message");
  assertEquals(p.body, "Ada sent you a message");
});

Deno.test("bundles count instead of listing", () => {
  assertEquals(
    composeBundle({ n: 3, kinds: ["message"], last_kind: "message", last_actor: "Bo", last_ref: "c" }).title,
    "3 new messages",
  );
  assertEquals(
    composeBundle({ n: 4, kinds: ["follow", "like"], last_kind: "like", last_actor: null, last_ref: null }).body,
    "4 new notifications",
  );
});

Deno.test("missing actor names fall back", () => {
  assertEquals(
    composeBundle({ n: 1, kinds: ["follow"], last_kind: "follow", last_actor: " ", last_ref: null }).body,
    "Someone followed you",
  );
  assertEquals(composeRing(null, "r", "c").body, "Someone is calling");
});
