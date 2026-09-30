// What a push says. Pure, so it's tested without a database.

export interface Bundle {
  n: number;
  kinds: string[];
  last_kind: string;
  last_actor: string | null;
  last_ref: string | null;
}

export interface PushPayload {
  /** notice | message | call — the app routes the tap on this. */
  t: "notice" | "message" | "call";
  title: string;
  body: string;
  ref?: string | null;
  room?: string;
}

export function composeBundle(b: Bundle): PushPayload {
  const who = b.last_actor?.trim() || "Someone";
  const onlyMessages = b.kinds.length === 1 && b.kinds[0] === "message";
  const t = b.last_kind === "message" ? "message" : "notice";
  if (b.n > 1) {
    return onlyMessages
      ? { t, title: `${b.n} new messages`, body: `Latest from ${who}`, ref: b.last_ref }
      : { t, title: "Peak", body: `${b.n} new notifications`, ref: b.last_ref };
  }
  const body = {
    like: `${who} liked your post`,
    reply: `${who} replied to you`,
    follow: `${who} followed you`,
    message: `${who} sent you a message`,
  }[b.last_kind] ?? "You have something new";
  return { t, title: "Peak", body, ref: b.last_ref };
}

export function composeRing(caller: string | null, room: string, conversation: string): PushPayload {
  return {
    t: "call",
    title: "Incoming call",
    body: `${caller?.trim() || "Someone"} is calling`,
    room,
    ref: conversation,
  };
}
