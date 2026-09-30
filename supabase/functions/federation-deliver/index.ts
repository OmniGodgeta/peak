// federation-deliver — sends queued ActivityPub activities (federation_job),
// signed as the local account. pg_cron calls it every minute.
//
//   create / delete / move  -> every remote follower's inbox (one POST per
//                              shared inbox), blocked servers skipped
//   accept / follow / unfollow / like / unlike -> the job's target_inbox
//
// Failures retry with backoff (finish_federation_job); after six attempts
// the job is dropped with its last error kept for 14 days.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import {
  accept,
  create,
  deleteNote,
  type Fed,
  follow,
  move,
  undo,
} from "../_shared/activitypub.ts";
import { signedPostHeaders } from "../_shared/httpsig.ts";
import { assertPublicHost } from "../_shared/public_host.ts";
import {
  ensureKey,
  fedConfig,
  federatedProfile,
  isBlocked,
  mediaUrl,
  service,
} from "../_shared/federation_store.ts";

interface Job {
  id: number;
  kind: string;
  local_profile_id: string;
  object_id: string | null;
  payload: Record<string, unknown>;
  target_inbox: string | null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const db = service();
  const fed = await fedConfig(db);
  if (!fed) return Response.json({ skipped: "federation off" });

  const { data, error } = await db.rpc("claim_federation_jobs", {
    p_limit: 50,
  });
  if (error) throw error;
  const jobs = (data ?? []) as Job[];
  let ok = 0, failed = 0;
  for (const job of jobs) {
    try {
      await run(db, fed, job);
      await db.rpc("finish_federation_job", { p_id: job.id, p_ok: true });
      ok++;
    } catch (e) {
      failed++;
      await db.rpc("finish_federation_job", {
        p_id: job.id,
        p_ok: false,
        p_error: (e instanceof Error ? e.message : String(e)).slice(0, 500),
      });
    }
  }
  return Response.json({ jobs: jobs.length, ok, failed });
});

async function run(db: SupabaseClient, fed: Fed, job: Job) {
  const me = await federatedProfile(db, { id: job.local_profile_id });
  // Opted out (or became ineligible) since queueing: nothing to send, except
  // telling followers a post is gone.
  if (!me && job.kind !== "delete") return;
  const handle = me?.handle ?? (await handleOf(db, job.local_profile_id));
  if (!handle) return;

  let activity: unknown;
  let inboxes: string[];
  switch (job.kind) {
    case "create": {
      const note = await noteFor(db, job.object_id!, handle);
      if (!note) return; // deleted or narrowed before we got to it
      activity = create(fed, note);
      inboxes = await followerInboxes(db, job.local_profile_id);
      break;
    }
    case "delete":
      activity = deleteNote(fed, job.object_id!, handle);
      inboxes = await followerInboxes(db, job.local_profile_id);
      break;
    case "move":
      activity = move(fed, handle, job.object_id!, String(job.payload.target));
      inboxes = await followerInboxes(db, job.local_profile_id);
      break;
    case "accept":
      activity = accept(fed, handle, crypto.randomUUID(), job.payload.follow);
      inboxes = [job.target_inbox!];
      break;
    case "follow":
      activity = follow(
        fed,
        handle,
        job.object_id!,
        String(job.payload.target),
      );
      inboxes = [job.target_inbox!];
      break;
    case "unfollow":
      activity = undo(
        fed,
        handle,
        crypto.randomUUID(),
        follow(fed, handle, job.object_id!, String(job.payload.target)),
      );
      inboxes = [job.target_inbox!];
      break;
    default:
      return;
  }

  const key = await ensureKey(db, job.local_profile_id);
  const body = JSON.stringify(activity);
  const errors: string[] = [];
  for (const inbox of inboxes) {
    try {
      const u = new URL(inbox);
      if (u.protocol !== "https:") throw new Error("https only");
      if (await isBlocked(db, u.host)) continue;
      await assertPublicHost(u);
      const headers = await signedPostHeaders(
        u,
        body,
        fed.keyId(handle),
        key.privatePem,
      );
      const res = await fetch(u, {
        method: "POST",
        headers,
        body,
        redirect: "manual",
        signal: AbortSignal.timeout(15_000),
      });
      await res.body?.cancel();
      // 4xx other than 408/429 won't get better by retrying.
      if (
        !res.ok &&
        (res.status >= 500 || res.status === 408 || res.status === 429)
      ) {
        errors.push(`${u.host}: ${res.status}`);
      }
    } catch (e) {
      errors.push(`${inbox}: ${e instanceof Error ? e.message : e}`);
    }
  }
  if (errors.length) throw new Error(errors.join("; "));
}

async function handleOf(
  db: SupabaseClient,
  id: string,
): Promise<string | null> {
  const { data } = await db.from("profile").select("handle").eq("id", id)
    .maybeSingle();
  return data?.handle ?? null;
}

async function followerInboxes(
  db: SupabaseClient,
  profileId: string,
): Promise<string[]> {
  const { data } = await db.from("remote_follower")
    .select("remote_actor:remote_actor_id (inbox, shared_inbox)")
    .eq("local_profile_id", profileId);
  const set = new Set<string>();
  for (
    const row of (data ?? []) as unknown as {
      remote_actor: { inbox: string; shared_inbox: string | null };
    }[]
  ) {
    set.add(row.remote_actor.shared_inbox ?? row.remote_actor.inbox);
  }
  return [...set];
}

async function noteFor(db: SupabaseClient, postId: string, handle: string) {
  const { data: p } = await db.from("post")
    .select(
      "id, body, title, content_warning, created_at, reply_to, visibility, deleted_at, community_id",
    )
    .eq("id", postId).maybeSingle();
  if (!p || p.visibility !== "public" || p.deleted_at || p.community_id) {
    return null;
  }
  const { data: media } = await db.from("post_media")
    .select("kind, storage_path, alt_text").eq("post_id", p.id).order(
      "sort_order",
    );
  return {
    id: p.id,
    authorHandle: handle,
    body: p.body ?? "",
    title: p.title,
    contentWarning: p.content_warning,
    createdAt: p.created_at,
    replyToLocalId: p.reply_to,
    replyToUri: null,
    attachments: (media ?? []).map((m) => ({
      url: mediaUrl(m.storage_path),
      mediaType: m.kind === "video"
        ? "video/mp4"
        : m.kind === "audio"
        ? "audio/mp4"
        : "image/jpeg",
      alt: m.alt_text,
    })),
  };
}
