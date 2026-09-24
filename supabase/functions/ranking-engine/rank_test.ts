import { assertEquals } from "jsr:@std/assert@1";
import { rankFeed, type RankPost, scorePost } from "./rank.ts";

const ctx = { nowMs: 10 * 3_600_000, lastVisitMs: null };

Deno.test("reaction, repost, reply, and follower counts do not change the score", () => {
  const base: RankPost = {
    id: "a",
    createdAtMs: 8 * 3_600_000,
    authorId: "u",
    mutual: false,
  };
  const counted = {
    ...base,
    reactionCount: 10_000,
    repostCount: 500,
    replyCount: 800,
    followerCount: 1_000_000,
  };
  const plain = scorePost(base, ctx);
  const noisy = scorePost(counted, ctx);
  assertEquals(noisy.score, plain.score);
  assertEquals(noisy.reason, plain.reason);
});

Deno.test("a mutual follow ranks above an identical post", () => {
  const createdAtMs = 9 * 3_600_000;
  const [mutual] = rankFeed([
    { id: "stranger", createdAtMs, authorId: "s", mutual: false },
    { id: "friend", createdAtMs, authorId: "f", mutual: true },
  ], ctx);
  assertEquals(mutual.id, "friend");
  assertEquals(mutual.reason, "You follow each other");
});

Deno.test("newer posts rank above older ones", () => {
  const [first] = rankFeed([
    {
      id: "old",
      createdAtMs: 0,
      authorId: "a",
      mutual: false,
    },
    {
      id: "new",
      createdAtMs: 9 * 3_600_000,
      authorId: "b",
      mutual: false,
    },
  ], ctx);
  assertEquals(first.id, "new");
});

Deno.test("one author does not take the whole top of the feed", () => {
  const createdAtMs = 9 * 3_600_000;
  const ranked = rankFeed([
    { id: "a1", createdAtMs, authorId: "same", mutual: false },
    { id: "a2", createdAtMs: createdAtMs - 1, authorId: "same", mutual: false },
    { id: "a3", createdAtMs: createdAtMs - 2, authorId: "same", mutual: false },
    {
      id: "other",
      createdAtMs: createdAtMs - 3,
      authorId: "else",
      mutual: false,
    },
  ], ctx);
  assertEquals(ranked[0].id, "a1");
  assertEquals(ranked[1].id, "other");
});
