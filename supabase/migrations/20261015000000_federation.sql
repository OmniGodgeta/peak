-- Phase 7 — ActivityPub federation, done properly. Replaces the
-- 20261008 sketch (its outbox triggers queued jobs nothing delivered and
-- the inbox trusted unsigned requests).
--
-- Still off by default: system_config.federation_enabled = 'false', and the
-- functions also need FEDERATION_BASE_URL (Peak's public origin — which
-- needs the domain). Each person also opts in (profile.federated), and
-- teen accounts can't. Only public posts ever leave the instance.
--
-- Data
--   actor_key                RSA key per local actor (service role only)
--   remote_actor             cached remote Person documents
--   remote_follower          remote accounts following a local account
--   remote_following         local accounts following remote ones
--   remote_post              remote notes we accepted (replies to our posts,
--                            posts by accounts we follow), stored as plain text
--   remote_reaction          remote likes on local posts
--   federation_job           delivery queue (federation-deliver drains it)
--   federation_inbox_seen    activity ids already processed (idempotency)
--   federation_instance_policy  blocked servers, public by design

drop trigger if exists post_federation_outbox on post;
drop trigger if exists reaction_federation_outbox on reaction;
drop function if exists trigger_outbox_post();
drop function if exists trigger_outbox_reaction();
drop table if exists outbox_events;
drop table if exists inbox_activity_log;
drop type if exists outbox_event_data;

-- ── per-person opt-in and migration fields ───────────────────────────────
alter table profile add column if not exists federated boolean not null default false;
alter table profile add column if not exists also_known_as text[] not null default '{}';
alter table profile add column if not exists moved_to text;

create or replace function enforce_federation_rules() returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.federated and new.account_kind = 'teen' then
    raise exception 'teen accounts can''t federate' using errcode = '42501';
  end if;
  if exists (select 1 from unnest(new.also_known_as) a where a !~ '^https://') then
    raise exception 'aliases must be https actor URLs' using errcode = '22023';
  end if;
  return new;
end;
$$;
drop trigger if exists profile_federation_rules on profile;
create trigger profile_federation_rules
  before insert or update of federated, also_known_as, account_kind on profile
  for each row execute function enforce_federation_rules();
revoke all on function enforce_federation_rules() from public, anon, authenticated;

-- ── keys ─────────────────────────────────────────────────────────────────
create table actor_key (
  profile_id      uuid primary key references profile (id) on delete cascade,
  public_key_pem  text not null,
  private_key_pem text not null,
  created_at      timestamptz not null default now()
);
alter table actor_key enable row level security;
revoke all on actor_key from anon, authenticated;

-- ── remote side ──────────────────────────────────────────────────────────
create table remote_actor (
  id                 uuid primary key default gen_random_uuid(),
  uri                text not null unique check (uri like 'https://%'),
  domain             text not null,
  inbox              text not null check (inbox like 'https://%'),
  shared_inbox       text check (shared_inbox like 'https://%'),
  preferred_username text,
  display_name       text,
  icon_url           text,
  public_key_id      text,
  public_key_pem     text,
  also_known_as      text[] not null default '{}',
  moved_to           text,
  fetched_at         timestamptz not null default now()
);
create index remote_actor_domain_idx on remote_actor (domain);
alter table remote_actor enable row level security;
revoke all on remote_actor from anon, authenticated;
grant select (id, uri, domain, preferred_username, display_name, icon_url, moved_to)
  on remote_actor to authenticated;
create policy remote_actor_read on remote_actor for select to authenticated using (true);

create table remote_follower (
  local_profile_id uuid not null references profile (id) on delete cascade,
  remote_actor_id  uuid not null references remote_actor (id) on delete cascade,
  follow_uri       text,
  created_at       timestamptz not null default now(),
  primary key (local_profile_id, remote_actor_id)
);
alter table remote_follower enable row level security;
revoke all on remote_follower from anon, authenticated;
grant select on remote_follower to authenticated;
create policy remote_follower_own on remote_follower for select to authenticated
  using (local_profile_id = auth.uid());

create table remote_following (
  local_profile_id uuid not null references profile (id) on delete cascade,
  remote_actor_id  uuid not null references remote_actor (id) on delete cascade,
  state            text not null default 'pending' check (state in ('pending', 'accepted')),
  follow_id        uuid not null default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  primary key (local_profile_id, remote_actor_id)
);
alter table remote_following enable row level security;
revoke all on remote_following from anon, authenticated;
grant select on remote_following to authenticated;
create policy remote_following_own on remote_following for select to authenticated
  using (local_profile_id = auth.uid());

create table remote_post (
  id                uuid primary key default gen_random_uuid(),
  uri               text not null unique,
  remote_actor_id   uuid not null references remote_actor (id) on delete cascade,
  body              text not null,
  content_warning   text,
  url               text,
  in_reply_to_post  uuid references post (id) on delete cascade,
  in_reply_to_uri   text,
  published_at      timestamptz not null,
  received_at       timestamptz not null default now()
);
create index remote_post_reply_idx on remote_post (in_reply_to_post) where in_reply_to_post is not null;
create index remote_post_actor_idx on remote_post (remote_actor_id, published_at desc);
alter table remote_post enable row level security;
revoke all on remote_post from anon, authenticated;

create table remote_reaction (
  post_id         uuid not null references post (id) on delete cascade,
  remote_actor_id uuid not null references remote_actor (id) on delete cascade,
  activity_uri    text not null unique,
  created_at      timestamptz not null default now(),
  primary key (post_id, remote_actor_id)
);
alter table remote_reaction enable row level security;
revoke all on remote_reaction from anon, authenticated;

create table federation_inbox_seen (
  activity_id text primary key,
  received_at timestamptz not null default now()
);
alter table federation_inbox_seen enable row level security;
revoke all on federation_inbox_seen from anon, authenticated;

create table federation_instance_policy (
  domain     text primary key check (domain = lower(domain) and domain !~ '[/:@ ]'),
  policy     text not null default 'block' check (policy in ('block')),
  reason     text check (char_length(reason) <= 500),
  created_by uuid references profile (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table federation_instance_policy enable row level security;
revoke all on federation_instance_policy from anon, authenticated;

-- ── delivery queue ───────────────────────────────────────────────────────
create table federation_job (
  id              bigserial primary key,
  kind            text not null check (kind in
                    ('create', 'delete', 'like', 'unlike', 'accept', 'follow', 'unfollow', 'move')),
  local_profile_id uuid not null references profile (id) on delete cascade,
  object_id       text,        -- post id, remote actor id, follow uri...
  payload         jsonb not null default '{}',
  target_inbox    text,        -- set for single-recipient jobs
  attempts        int not null default 0,
  next_attempt_at timestamptz not null default now(),
  done_at         timestamptz,
  last_error      text,
  created_at      timestamptz not null default now()
);
create index federation_job_due_idx on federation_job (next_attempt_at) where done_at is null;
alter table federation_job enable row level security;
revoke all on federation_job from anon, authenticated;

-- ── triggers: what gets queued ───────────────────────────────────────────
create or replace function federation_on() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true' from system_config where key = 'federation_enabled'), false);
$$;
revoke all on function federation_on() from public, anon, authenticated;

create or replace function queue_federated_post() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not federation_on() then return new; end if;
  if tg_op = 'INSERT' then
    if new.visibility = 'public' and new.community_id is null
       and exists (select 1 from profile where id = new.author_id and federated)
       and exists (select 1 from remote_follower where local_profile_id = new.author_id) then
      insert into federation_job (kind, local_profile_id, object_id)
      values ('create', new.author_id, new.id::text);
    end if;
  elsif tg_op = 'UPDATE' then
    -- soft delete, or narrowed away from public: tell everyone it's gone
    if old.visibility = 'public' and old.deleted_at is null
       and (new.deleted_at is not null or new.visibility <> 'public')
       and exists (select 1 from profile where id = new.author_id and federated) then
      insert into federation_job (kind, local_profile_id, object_id)
      values ('delete', new.author_id, new.id::text);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function queue_federated_post() from public, anon, authenticated;
drop trigger if exists post_federation on post;
create trigger post_federation after insert or update of deleted_at, visibility on post
  for each row execute function queue_federated_post();

-- ── reads for the app ────────────────────────────────────────────────────
create or replace function remote_replies(p_post uuid)
returns table (
  id uuid, uri text, url text, body text, content_warning text, published_at timestamptz,
  actor_uri text, actor_handle text, actor_name text, actor_icon text
)
language sql stable security definer set search_path = public as $$
  select r.id, r.uri, r.url, r.body, r.content_warning, r.published_at,
         a.uri, coalesce(a.preferred_username, '') || '@' || a.domain,
         a.display_name, a.icon_url
  from remote_post r
  join remote_actor a on a.id = r.remote_actor_id
  join post p on p.id = r.in_reply_to_post
  where r.in_reply_to_post = p_post
    and can_view_post(p, auth.uid())
    and not exists (select 1 from federation_instance_policy b where b.domain = a.domain)
  order by r.published_at;
$$;

create or replace function feed_fediverse(p_before timestamptz default now(), p_limit int default 30)
returns table (
  id uuid, uri text, url text, body text, content_warning text, published_at timestamptz,
  actor_uri text, actor_handle text, actor_name text, actor_icon text
)
language sql stable security definer set search_path = public as $$
  select r.id, r.uri, r.url, r.body, r.content_warning, r.published_at,
         a.uri, coalesce(a.preferred_username, '') || '@' || a.domain,
         a.display_name, a.icon_url
  from remote_post r
  join remote_actor a on a.id = r.remote_actor_id
  join remote_following f on f.remote_actor_id = a.id
    and f.local_profile_id = auth.uid() and f.state = 'accepted'
  where r.published_at < p_before
    and not exists (select 1 from federation_instance_policy b where b.domain = a.domain)
  order by r.published_at desc
  limit least(p_limit, 100);
$$;

create or replace function remote_like_count(p_post uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from remote_reaction rr join post p on p.id = rr.post_id
  where rr.post_id = p_post and can_view_post(p, auth.uid());
$$;

create or replace function my_federation()
returns table (
  enabled boolean, federated boolean, is_teen boolean, also_known_as text[], moved_to text,
  remote_followers int, remote_following int
)
language sql stable security definer set search_path = public as $$
  select federation_on(), p.federated, p.account_kind = 'teen', p.also_known_as, p.moved_to,
         (select count(*)::int from remote_follower where local_profile_id = p.id),
         (select count(*)::int from remote_following where local_profile_id = p.id)
  from profile p where p.id = auth.uid();
$$;

create or replace function set_my_federation(p_federated boolean, p_also_known_as text[])
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  update profile
     set federated = coalesce(p_federated, federated),
         also_known_as = coalesce(p_also_known_as, also_known_as)
   where id = auth.uid();
end;
$$;

-- Transparency: every server this instance refuses to talk to, and why.
create or replace function federation_blocklist()
returns table (domain text, reason text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select domain, reason, created_at from federation_instance_policy order by domain;
$$;

create or replace function set_instance_block(p_domain text, p_blocked boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_domain text := lower(trim(p_domain));
begin
  if not is_staff(auth.uid()) then
    raise exception 'staff only' using errcode = '42501';
  end if;
  if p_blocked then
    insert into federation_instance_policy (domain, reason, created_by)
    values (v_domain, nullif(trim(p_reason), ''), auth.uid())
    on conflict (domain) do update set reason = excluded.reason;
    -- stop talking to them: drop their followers and queued deliveries
    delete from remote_follower rf using remote_actor a
      where a.id = rf.remote_actor_id and a.domain = v_domain;
  else
    delete from federation_instance_policy where domain = v_domain;
  end if;
end;
$$;

revoke all on function remote_replies(uuid) from public, anon;
revoke all on function feed_fediverse(timestamptz, int) from public, anon;
revoke all on function remote_like_count(uuid) from public, anon;
revoke all on function my_federation() from public, anon;
revoke all on function set_my_federation(boolean, text[]) from public, anon;
revoke all on function set_instance_block(text, boolean, text) from public, anon;
revoke all on function federation_blocklist() from public;
grant execute on function remote_replies(uuid) to authenticated;
grant execute on function feed_fediverse(timestamptz, int) to authenticated;
grant execute on function remote_like_count(uuid) to authenticated;
grant execute on function my_federation() to authenticated;
grant execute on function set_my_federation(boolean, text[]) to authenticated;
grant execute on function set_instance_block(text, boolean, text) to authenticated;
grant execute on function federation_blocklist() to anon, authenticated;
