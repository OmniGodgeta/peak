// ActivityPub / WebFinger / NodeInfo documents for Peak. Pure functions of
// their inputs, so they're unit-tested without a server.
//
// Addresses, given base = FEDERATION_BASE_URL (e.g. https://peak.social):
//   actor      {base}/users/{handle}        inbox {actor}/inbox
//   note       {base}/posts/{post id}       shared inbox {base}/inbox
//   followers  {actor}/followers            outbox {actor}/outbox

export const AS_PUBLIC = "https://www.w3.org/ns/activitystreams#Public";
const CONTEXT = [
  "https://www.w3.org/ns/activitystreams",
  "https://w3id.org/security/v1",
];

export class Fed {
  constructor(readonly base: string) {
    this.base = base.replace(/\/+$/, "");
  }
  get domain() {
    return new URL(this.base).host;
  }
  actor(handle: string) {
    return `${this.base}/users/${encodeURIComponent(handle)}`;
  }
  keyId(handle: string) {
    return `${this.actor(handle)}#main-key`;
  }
  note(postId: string) {
    return `${this.base}/posts/${postId}`;
  }
  sharedInbox() {
    return `${this.base}/inbox`;
  }
  activity(kind: string, id: string) {
    return `${this.base}/activities/${kind}/${id}`;
  }

  /** The local post id a note URI of ours points at, or null. */
  localPostId(uri: string | null | undefined): string | null {
    if (!uri) return null;
    const m = uri.match(/\/posts\/([0-9a-f-]{36})$/);
    return m && uri.startsWith(this.base + "/posts/") ? m[1] : null;
  }

  /** The local handle an actor URI of ours points at, or null. */
  localHandle(uri: string | null | undefined): string | null {
    if (!uri || !uri.startsWith(this.base + "/users/")) return null;
    const rest = uri.slice((this.base + "/users/").length);
    return rest && !rest.includes("/") ? decodeURIComponent(rest) : null;
  }
}

export interface LocalActor {
  handle: string;
  displayName: string | null;
  bio: string | null;
  avatarUrl: string | null;
  publicKeyPem: string;
  alsoKnownAs: string[];
  movedTo: string | null;
  createdAt: string;
}

export function actorDoc(f: Fed, a: LocalActor) {
  const id = f.actor(a.handle);
  return {
    "@context": CONTEXT,
    id,
    type: "Person",
    preferredUsername: a.handle,
    name: a.displayName || a.handle,
    summary: a.bio ? textToHtml(a.bio) : "",
    url: id,
    inbox: `${id}/inbox`,
    outbox: `${id}/outbox`,
    followers: `${id}/followers`,
    endpoints: { sharedInbox: f.sharedInbox() },
    manuallyApprovesFollowers: false,
    discoverable: true,
    published: a.createdAt,
    ...(a.avatarUrl ? { icon: { type: "Image", url: a.avatarUrl } } : {}),
    ...(a.alsoKnownAs.length ? { alsoKnownAs: a.alsoKnownAs } : {}),
    ...(a.movedTo ? { movedTo: a.movedTo } : {}),
    publicKey: {
      id: f.keyId(a.handle),
      owner: id,
      publicKeyPem: a.publicKeyPem,
    },
  };
}

export interface LocalNote {
  id: string;
  authorHandle: string;
  body: string;
  title: string | null;
  contentWarning: string | null;
  createdAt: string;
  /** Local post id this replies to, or a remote note URI. */
  replyToLocalId: string | null;
  replyToUri: string | null;
  attachments: { url: string; mediaType: string; alt: string | null }[];
}

export function noteDoc(f: Fed, n: LocalNote) {
  const actor = f.actor(n.authorHandle);
  const body = n.title ? `${n.title}\n\n${n.body}` : n.body;
  return {
    id: f.note(n.id),
    type: "Note",
    attributedTo: actor,
    content: textToHtml(body),
    published: n.createdAt,
    url: f.note(n.id),
    to: [AS_PUBLIC],
    cc: [`${actor}/followers`],
    inReplyTo: n.replyToLocalId ? f.note(n.replyToLocalId) : n.replyToUri,
    sensitive: !!n.contentWarning,
    summary: n.contentWarning || null,
    attachment: n.attachments.map((a) => ({
      type: "Document",
      mediaType: a.mediaType,
      url: a.url,
      name: a.alt,
    })),
  };
}

export function create(f: Fed, n: LocalNote) {
  const note = noteDoc(f, n);
  return {
    "@context": CONTEXT,
    id: f.activity("create", n.id),
    type: "Create",
    actor: note.attributedTo,
    published: note.published,
    to: note.to,
    cc: note.cc,
    object: note,
  };
}

export function deleteNote(f: Fed, postId: string, authorHandle: string) {
  return {
    "@context": CONTEXT,
    id: f.activity("delete", postId),
    type: "Delete",
    actor: f.actor(authorHandle),
    to: [AS_PUBLIC],
    object: { id: f.note(postId), type: "Tombstone" },
  };
}

export function accept(f: Fed, handle: string, id: string, follow: unknown) {
  return {
    "@context": CONTEXT,
    id: f.activity("accept", id),
    type: "Accept",
    actor: f.actor(handle),
    object: follow,
  };
}

export function follow(f: Fed, handle: string, id: string, target: string) {
  return {
    "@context": CONTEXT,
    id: f.activity("follow", id),
    type: "Follow",
    actor: f.actor(handle),
    object: target,
  };
}

export function undo(f: Fed, handle: string, id: string, inner: unknown) {
  return {
    "@context": CONTEXT,
    id: f.activity("undo", id),
    type: "Undo",
    actor: f.actor(handle),
    object: inner,
  };
}

export function like(f: Fed, handle: string, id: string, objectUri: string) {
  return {
    "@context": CONTEXT,
    id: f.activity("like", id),
    type: "Like",
    actor: f.actor(handle),
    object: objectUri,
  };
}

export function move(f: Fed, handle: string, id: string, target: string) {
  const actor = f.actor(handle);
  return {
    "@context": CONTEXT,
    id: f.activity("move", id),
    type: "Move",
    actor,
    object: actor,
    target,
  };
}

export function webfinger(f: Fed, handle: string) {
  return {
    subject: `acct:${handle}@${f.domain}`,
    aliases: [f.actor(handle)],
    links: [
      { rel: "self", type: "application/activity+json", href: f.actor(handle) },
      {
        rel: "http://webfinger.net/rel/profile-page",
        type: "text/html",
        href: f.actor(handle),
      },
    ],
  };
}

export function nodeinfo(users: number, posts: number, version: string) {
  return {
    version: "2.0",
    software: { name: "peak", version },
    protocols: ["activitypub"],
    services: { inbound: [], outbound: [] },
    openRegistrations: false,
    usage: { users: { total: users }, localPosts: posts },
    metadata: { nodeName: "Peak" },
  };
}

// ── text ─────────────────────────────────────────────────────────────────

export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/** Peak's plain text → the minimal HTML ActivityPub expects. */
export function textToHtml(text: string): string {
  return text.trim().split(/\n{2,}/).map((p) =>
    `<p>${escapeHtml(p).replace(/\n/g, "<br>")}</p>`
  ).join("");
}

const ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  "#39": "'",
};

/**
 * Remote HTML → plain text. Peak never renders remote HTML; this keeps line
 * structure and drops every tag, attribute and script.
 */
export function htmlToText(html: string, max = 5000): string {
  const text = html
    .replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|blockquote|h[1-6])>/gi, "\n\n")
    .replace(/<[^>]*>/g, "")
    .replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e: string) => {
      if (e[0] === "#") {
        const n = e[1] === "x" || e[1] === "X"
          ? parseInt(e.slice(2), 16)
          : parseInt(e.slice(1), 10);
        return Number.isFinite(n) && n > 0 && n < 0x110000
          ? String.fromCodePoint(n)
          : "";
      }
      return ENTITIES[e.toLowerCase()] ?? m;
    })
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return text.length > max ? text.slice(0, max) + "…" : text;
}

/** First string of an AP field that may be a string, object or array. */
export function idOf(v: unknown): string | null {
  if (typeof v === "string") return v;
  if (Array.isArray(v)) return v.length ? idOf(v[0]) : null;
  if (
    v && typeof v === "object" && typeof (v as { id?: unknown }).id === "string"
  ) {
    return (v as { id: string }).id;
  }
  return null;
}
