// Open ranker. Order comes from recency, a mutual follow, time since the
// viewer's last visit, and a short author-diversity pass.
//
// Reaction, repost, reply, and follower counts are not inputs. A test pins
// that: adding them to a post must not change its score.

export interface RankPost {
  id: string;
  createdAtMs: number;
  authorId: string;
  mutual: boolean;
}

export interface RankContext {
  nowMs: number;
  lastVisitMs: number | null;
}

export interface Ranked {
  id: string;
  score: number;
  reason: string;
}

const DIVERSITY_WINDOW = 3;

export function scorePost(
  post: RankPost,
  ctx: RankContext,
): { score: number; reason: string } {
  const ageHours = Math.max(0, (ctx.nowMs - post.createdAtMs) / 3_600_000);
  let score = 1 / Math.pow(ageHours + 2, 1.2);
  let reason = "Recent";
  if (post.mutual) {
    score += 0.35;
    reason = "You follow each other";
  }
  if (ctx.lastVisitMs != null && post.createdAtMs > ctx.lastVisitMs) {
    score += 0.15;
    if (!post.mutual) reason = "New since you were last here";
  }
  return { score, reason };
}

export function rankFeed(posts: RankPost[], ctx: RankContext): Ranked[] {
  const scored = posts.map((post) => ({ post, ...scorePost(post, ctx) }));
  scored.sort((a, b) =>
    b.score - a.score || b.post.createdAtMs - a.post.createdAtMs
  );

  const placed: typeof scored = [];
  const deferred: typeof scored = [];
  const recentAuthors: string[] = [];
  for (const item of scored) {
    if (recentAuthors.includes(item.post.authorId)) {
      deferred.push(item);
      continue;
    }
    placed.push(item);
    recentAuthors.push(item.post.authorId);
    if (recentAuthors.length > DIVERSITY_WINDOW) recentAuthors.shift();
  }
  placed.push(...deferred);
  return placed.map(({ post, score, reason }) => ({
    id: post.id,
    score,
    reason,
  }));
}
