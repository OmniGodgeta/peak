-- ShadowChat — Phase 1: posts, media, reactions, replies, reposts
-- Chronological feed only in this phase. Ranking + fan-out index land in Phase 5.

create type post_visibility as enum ('circles', 'public', 'mentioned', 'followers');
create type reply_policy    as enum ('everyone', 'followers', 'circles', 'mentioned', 'nobody');
create type quote_policy    as enum ('allow', 'ask', 'disallow');
create type media_kind      as enum ('image', 'video', 'audio');
create type reaction_kind   as enum ('like', 'celebrate', 'support', 'insightful', 'curious');

-- ─────────────────────────────────────────────────────────────────────────────
-- post
-- ─────────────────────────────────────────────────────────────────────────────
create table post (
  id             uuid primary key default gen_random_uuid(),
  author_id      uuid not null references profile (id) on delete cascade,
  persona_id     uuid not null references persona (id) on delete cascade,
  body           text not null default '' check (char_length(body) <= 5000),
  lang           text,
  visibility     post_visibility not null default 'circles',
  reply_to       uuid references post (id) on delete cascade,
  root_id        uuid references post (id) on delete cascade,
  quote_of       uuid references post (id) on delete set null,
  reply_policy   reply_policy not null default 'everyone',
  quote_policy   quote_policy not null default 'allow',
  content_warning text check (char_length(content_warning) <= 120),
  is_sensitive   boolean not null default false,
  edited_at      timestamptz,
  deleted_at     timestamptz,          -- soft-delete; a sweep hard-deletes after the retention window
  created_at     timestamptz not null default now(),
  -- a reply carries both reply_to and root_id; a top-level post carries neither
  check ((reply_to is null) = (root_id is null))
);

create index post_author_created_idx on post (author_id, created_at desc) where deleted_at is null;
create index post_root_idx           on post (root_id) where deleted_at is null;
create index post_reply_to_idx       on post (reply_to) where deleted_at is null;

create or replace function stamp_edited_at() returns trigger
language plpgsql as $$
begin
  new.edited_at = now();
  return new;
end;
$$;

create trigger post_edited_at before update on post
  for each row when (old.body is distinct from new.body)
  execute function stamp_edited_at();

-- post_audience: which of the author's circles a 'circles' post is addressed to
create table post_audience (
  post_id    uuid not null references post (id) on delete cascade,
  circle_id  uuid not null references circle (id) on delete cascade,
  primary key (post_id, circle_id)
);

-- post_media
create table post_media (
  id           uuid primary key default gen_random_uuid(),
  post_id      uuid not null references post (id) on delete cascade,
  kind         media_kind not null,
  storage_path text not null,
  alt_text     text check (char_length(alt_text) <= 1000),
  width        int,
  height       int,
  duration_ms  int,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now()
);

create index post_media_post_idx on post_media (post_id);

-- reaction
create table reaction (
  post_id    uuid not null references post (id) on delete cascade,
  actor_id   uuid not null references profile (id) on delete cascade,
  kind       reaction_kind not null default 'like',
  created_at timestamptz not null default now(),
  primary key (post_id, actor_id)
);

create index reaction_post_idx on reaction (post_id);

-- repost (no-comment boost). Quote-posts are just posts with quote_of set.
create table repost (
  post_id    uuid not null references post (id) on delete cascade,
  actor_id   uuid not null references profile (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, actor_id)
);

-- mention (resolved at publish time by the `publish` Edge Function)
create table mention (
  post_id      uuid not null references post (id) on delete cascade,
  mentioned_id uuid not null references profile (id) on delete cascade,
  primary key (post_id, mentioned_id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Visibility helper: can `viewer` see `post`?
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function can_view_post(p_post post, viewer uuid) returns boolean
language sql stable as $$
  select
    p_post.deleted_at is null
    and not blocked_between(viewer, p_post.author_id)
    and (
      p_post.author_id = viewer
      or (p_post.visibility = 'public')
      or (p_post.visibility = 'followers'
          and exists (select 1 from follow f
                      where f.follower_id = viewer and f.followee_id = p_post.author_id))
      or (p_post.visibility = 'mentioned'
          and exists (select 1 from mention m
                      where m.post_id = p_post.id and m.mentioned_id = viewer))
      or (p_post.visibility = 'circles'
          and exists (
            select 1
            from post_audience pa
            join circle_member cm on cm.circle_id = pa.circle_id
            where pa.post_id = p_post.id and cm.member_id = viewer
          ))
      or (p_post.visibility = 'circles'
          and exists (
            select 1 from post_audience pa
            join circle c on c.id = pa.circle_id
            where pa.post_id = p_post.id and c.is_public
          ))
    );
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Chronological feed: latest posts from accounts the viewer follows (plus own),
-- visibility-filtered, mute-filtered. `friends_first` just reorders client-side
-- using circle proximity returned here.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function feed_latest(p_before timestamptz default now(), p_limit int default 30)
returns setof post
language sql stable as $$
  select p.*
  from post p
  where p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and (
      p.author_id = auth.uid()
      or exists (select 1 from follow f
                 where f.follower_id = auth.uid() and f.followee_id = p.author_id)
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

-- lightweight aggregate counts (counts are private-by-default in the UI, but the
-- author and permitted viewers can request them)
create or replace function post_counts(p_post_id uuid)
returns table (reactions bigint, replies bigint, reposts bigint)
language sql stable as $$
  select
    (select count(*) from reaction r where r.post_id = p_post_id),
    (select count(*) from post pr where pr.reply_to = p_post_id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p_post_id);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- RLS
-- ─────────────────────────────────────────────────────────────────────────────
alter table post          enable row level security;
alter table post_audience enable row level security;
alter table post_media    enable row level security;
alter table reaction      enable row level security;
alter table repost        enable row level security;
alter table mention       enable row level security;

-- post: see it if can_view_post; write only your own; author_id must be you and
-- persona must belong to you.
create policy post_select on post for select using (can_view_post(post, auth.uid()));
create policy post_insert on post for insert with check (
  author_id = auth.uid()
  and exists (select 1 from persona pe where pe.id = persona_id and pe.account_id = auth.uid())
);
create policy post_update on post for update using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy post_delete on post for delete using (author_id = auth.uid());

-- post_audience: manageable by the post's author; readable if you can read the post
create policy post_audience_select on post_audience for select using (
  exists (select 1 from post p where p.id = post_id and can_view_post(p, auth.uid()))
);
create policy post_audience_write on post_audience for all using (
  exists (select 1 from post p where p.id = post_id and p.author_id = auth.uid())
) with check (
  exists (select 1 from post p where p.id = post_id and p.author_id = auth.uid())
  and exists (select 1 from circle c where c.id = circle_id and c.owner_id = auth.uid())
);

-- post_media: follows the post
create policy post_media_select on post_media for select using (
  exists (select 1 from post p where p.id = post_id and can_view_post(p, auth.uid()))
);
create policy post_media_write on post_media for all using (
  exists (select 1 from post p where p.id = post_id and p.author_id = auth.uid())
) with check (
  exists (select 1 from post p where p.id = post_id and p.author_id = auth.uid())
);

-- reaction / repost: visible where the post is; you act as yourself; respects blocks
create policy reaction_select on reaction for select using (
  exists (select 1 from post p where p.id = post_id and can_view_post(p, auth.uid()))
);
create policy reaction_write on reaction for all using (actor_id = auth.uid())
  with check (
    actor_id = auth.uid()
    and exists (select 1 from post p where p.id = post_id and can_view_post(p, auth.uid()))
  );

create policy repost_select on repost for select using (
  exists (select 1 from post p where p.id = post_id and can_view_post(p, auth.uid()))
);
create policy repost_write on repost for all using (actor_id = auth.uid())
  with check (
    actor_id = auth.uid()
    and exists (
      select 1 from post p
      where p.id = post_id and can_view_post(p, auth.uid()) and p.quote_policy <> 'disallow'
    )
  );

-- mention: readable with the post; only the post author's publish path writes it
create policy mention_select on mention for select using (
  mentioned_id = auth.uid()
  or exists (select 1 from post p where p.id = post_id and can_view_post(p, auth.uid()))
);
create policy mention_write on mention for all using (
  exists (select 1 from post p where p.id = post_id and p.author_id = auth.uid())
) with check (
  exists (select 1 from post p where p.id = post_id and p.author_id = auth.uid())
);
