-- Peak — Phase 5: custom feeds (rule sets, shareable).
--
-- A custom_feed is a name + a small jsonb rule set. feed_custom compiles the
-- rules into a query, still gated by can_view_post so a feed never shows
-- anything the viewer couldn't already see. Feeds can be public; anyone can
-- copy a public one.
--
-- rules shape (all keys optional):
--   { "communities": [uuid],   -- posts in any of these communities
--     "from":        [uuid],   -- posts by any of these people
--     "any_words":   [text],   -- body contains any of these
--     "not_words":   [text],   -- body contains none of these
--     "only_media":  bool }    -- only posts with an attachment
-- With no positive rule (communities / from / any_words) the feed falls back to
-- people you follow, so the remaining rules act as filters on your feed.

create table custom_feed (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references profile (id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  rules      jsonb not null default '{}',
  is_public  boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index custom_feed_by_owner on custom_feed (owner_id, name);

alter table custom_feed enable row level security;
create policy custom_feed_select on custom_feed for select
  using (owner_id = auth.uid() or is_public);
create policy custom_feed_write on custom_feed for all
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create trigger custom_feed_updated_at before update on custom_feed
  for each row execute function set_updated_at();

-- copy a public feed (or your own) into a new feed you own
create or replace function copy_custom_feed(p_feed_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_src custom_feed; v_id uuid;
begin
  select * into v_src from custom_feed
  where id = p_feed_id and (owner_id = auth.uid() or is_public);
  if v_src.id is null then raise exception 'feed not found'; end if;
  insert into custom_feed (owner_id, name, rules, is_public)
  values (auth.uid(), left(v_src.name || ' (copy)', 60), v_src.rules, false)
  returning id into v_id;
  return v_id;
end;
$$;

-- the compiled feed
create or replace function feed_custom(
  p_feed_id uuid,
  p_before timestamptz default now(),
  p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, reason text
)
language plpgsql stable security definer set search_path = public as $$
declare
  r jsonb;
  has_positive boolean;
begin
  select cf.rules into r from custom_feed cf
  where cf.id = p_feed_id and (cf.owner_id = auth.uid() or cf.is_public);
  if r is null then raise exception 'feed not found'; end if;

  has_positive :=
    (jsonb_array_length(coalesce(r->'communities', '[]')) > 0) or
    (jsonb_array_length(coalesce(r->'from', '[]')) > 0) or
    (jsonb_array_length(coalesce(r->'any_words', '[]')) > 0);

  return query
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction rc where rc.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction rc where rc.post_id = p.id and rc.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    'From a custom feed'::text
  from post p
  join profile a on a.id = p.author_id
  where p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
    -- no positive rule → fall back to your follow graph
    and (
      has_positive
      or p.author_id = auth.uid()
      or exists (select 1 from follow f
                 where f.follower_id = auth.uid() and f.followee_id = p.author_id)
    )
    -- communities
    and (
      jsonb_array_length(coalesce(r->'communities', '[]')) = 0
      or p.community_id in (
        select (jsonb_array_elements_text(r->'communities'))::uuid)
    )
    -- from
    and (
      jsonb_array_length(coalesce(r->'from', '[]')) = 0
      or p.author_id in (
        select (jsonb_array_elements_text(r->'from'))::uuid)
    )
    -- any_words
    and (
      jsonb_array_length(coalesce(r->'any_words', '[]')) = 0
      or exists (
        select 1 from jsonb_array_elements_text(r->'any_words') w
        where p.body ilike '%' || w || '%'
           or coalesce(p.title, '') ilike '%' || w || '%')
    )
    -- not_words
    and not exists (
      select 1 from jsonb_array_elements_text(coalesce(r->'not_words', '[]')) w
      where p.body ilike '%' || w || '%'
    )
    -- only_media
    and (
      coalesce((r->>'only_media')::boolean, false) = false
      or exists (select 1 from post_media pm where pm.post_id = p.id)
    )
  order by p.created_at desc
  limit least(p_limit, 100);
end;
$$;

revoke all on function copy_custom_feed(uuid)            from public;
revoke all on function feed_custom(uuid, timestamptz, int) from public;
grant execute on function copy_custom_feed(uuid)          to authenticated;
grant execute on function feed_custom(uuid, timestamptz, int) to authenticated;
