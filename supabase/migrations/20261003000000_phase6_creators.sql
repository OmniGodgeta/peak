-- Phase 6, the part that does not touch money.
-- Personas were already a table. Boosts are Discover-only and labelled.
-- Latest does not read post_boost. Reach numbers are opt-in and only yours.

-- ── Personas ────────────────────────────────────────────────────────────────

create or replace function create_persona(p_label text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_label text := btrim(p_label);
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if v_label is null or char_length(v_label) < 1 or char_length(v_label) > 40 then
    raise exception 'Persona name must be 1–40 characters';
  end if;
  if (select count(*) from persona where account_id = auth.uid()) >= 5 then
    raise exception 'You can have up to 5 personas';
  end if;
  insert into persona (account_id, label, is_default)
  values (auth.uid(), v_label, false)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function set_default_persona(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from persona where id = p_id and account_id = auth.uid()
  ) then
    raise exception 'That persona is not yours';
  end if;
  update persona set is_default = false where account_id = auth.uid();
  update persona set is_default = true where id = p_id;
end;
$$;

revoke all on function create_persona(text) from public;
revoke all on function set_default_persona(uuid) from public;
grant execute on function create_persona(text) to authenticated;
grant execute on function set_default_persona(uuid) to authenticated;

-- ── Discover boosts ─────────────────────────────────────────────────────────
-- A boost never changes Latest. For You (adults only) may surface it, and
-- the row's reason always says it was boosted.

create table post_boost (
  post_id    uuid primary key references post (id) on delete cascade,
  booster_id uuid not null references profile (id) on delete cascade,
  created_at timestamptz not null default now(),
  ends_at    timestamptz not null
);

alter table post_boost enable row level security;

create policy post_boost_select_own on post_boost
  for select using (booster_id = auth.uid());

create or replace function boost_my_post(p_post_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ends timestamptz := now() + interval '7 days';
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if (select account_kind from profile where id = auth.uid()) = 'teen' then
    raise exception 'Teen accounts do not boost posts';
  end if;
  if not exists (
    select 1 from post
    where id = p_post_id
      and author_id = auth.uid()
      and reply_to is null
      and deleted_at is null
      and visibility = 'public'
  ) then
    raise exception 'Only your own public posts can be boosted';
  end if;
  insert into post_boost (post_id, booster_id, ends_at)
  values (p_post_id, auth.uid(), v_ends)
  on conflict (post_id) do update
    set ends_at = excluded.ends_at,
        created_at = now(),
        booster_id = excluded.booster_id;
  return v_ends;
end;
$$;

create or replace function unboost_my_post(p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from post_boost
  where post_id = p_post_id
    and booster_id = auth.uid();
end;
$$;

revoke all on function boost_my_post(uuid) from public;
revoke all on function unboost_my_post(uuid) from public;
grant execute on function boost_my_post(uuid) to authenticated;
grant execute on function unboost_my_post(uuid) to authenticated;

-- For You: same row shape, boosts first for adults, hidden from teens.
create or replace function recommend_posts_for_user(p_limit int default 30)
returns table (
    id uuid,
    body text,
    content_warning text,
    is_sensitive boolean,
    visibility post_visibility,
    created_at timestamptz,
    edited_at timestamptz,
    author_id uuid,
    author_handle citext,
    author_domain text,
    author_display_name text,
    author_is_teen boolean,
    author_avatar_path text,
    reaction_count bigint,
    reply_count bigint,
    repost_count bigint,
    viewer_reacted boolean,
    viewer_reposted boolean,
    media jsonb,
    title text,
    long_form boolean,
    is_pinned boolean,
    community_label text,
    community_label_note text,
    author_flair text,
    channel_id uuid,
    channel_name text,
    reason text,
    reply_to uuid,
    depth int,
    author_is_verified boolean
)
language sql stable set search_path = public as $$
  with interests as (
    select coalesce(array_agg(topic), '{}'::text[]) as topics
    from profile_interest
    where profile_id = auth.uid()
  ),
  viewer as (
    select coalesce(
      (select account_kind <> 'teen' from profile where id = auth.uid()),
      false
    ) as adult
  )
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at, p.author_id, a.handle, a.domain,
    a.display_name, (a.account_kind = 'teen'), a.avatar_path,
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    false,
    null::text, null::text, null::text, p.channel_id, null::text,
    case
      when v.adult and exists (
        select 1 from post_boost b
        where b.post_id = p.id and b.ends_at > now()
      ) then 'Boosted — the author asked for this in Discover only. It does not change anyone''s Latest feed.'
      when exists (select 1 from post_media pm
                   where pm.post_id = p.id and pm.kind = 'video')
        then 'Video on Peak'
      when p.community_id is not null
           and exists (select 1 from community_member cm
                       where cm.community_id = p.community_id
                         and cm.member_id = auth.uid()
                         and cm.state = 'active')
        then 'In a space you joined'
      else 'Matches an interest'
    end,
    p.reply_to, 0,
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  cross join interests i
  cross join viewer v
  where p.deleted_at is null
    and p.reply_to is null
    and p.visibility = 'public'
    and p.author_id is distinct from auth.uid()
    and not (
      not v.adult
      and exists (
        select 1 from post_boost b
        where b.post_id = p.id and b.ends_at > now()
      )
    )
    and (
      (v.adult and exists (
        select 1 from post_boost b
        where b.post_id = p.id and b.ends_at > now()
      ))
      or exists (select 1 from post_media pm
                 where pm.post_id = p.id and pm.kind = 'video')
      or (
        p.community_id is not null
        and exists (select 1 from community_member cm
                    where cm.community_id = p.community_id
                      and cm.member_id = auth.uid()
                      and cm.state = 'active')
      )
      or exists (
        select 1 from community c
        where c.id = p.community_id
          and c.topics && i.topics
      )
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by
    case
      when v.adult and exists (
        select 1 from post_boost b
        where b.post_id = p.id and b.ends_at > now()
      ) then 0 else 1
    end,
    p.created_at desc
  limit least(p_limit, 100);
$$;

-- ── Reach, opt-in, your posts only ──────────────────────────────────────────

alter table profile_private
  add column if not exists analytics_opt_in boolean not null default false;

create or replace function set_analytics_opt_in(p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update profile_private
  set analytics_opt_in = p_on
  where id = auth.uid();
end;
$$;

create or replace function my_post_stats()
returns table (
  opted_in boolean,
  posts int,
  likes int,
  replies int,
  reposts int,
  active_boosts int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if not coalesce(
    (select analytics_opt_in from profile_private where id = auth.uid()),
    false
  ) then
    return query select false, null::int, null::int, null::int, null::int, null::int;
    return;
  end if;
  return query
  select
    true,
    (select count(*)::int from post p
      where p.author_id = auth.uid() and p.deleted_at is null and p.reply_to is null),
    (select count(*)::int from reaction r
      join post p on p.id = r.post_id
      where p.author_id = auth.uid() and p.deleted_at is null),
    (select count(*)::int from post r
      join post p on p.id = r.reply_to
      where p.author_id = auth.uid() and r.deleted_at is null and r.author_id <> auth.uid()),
    (select count(*)::int from repost rp
      join post p on p.id = rp.post_id
      where p.author_id = auth.uid() and p.deleted_at is null),
    (select count(*)::int from post_boost b
      where b.booster_id = auth.uid() and b.ends_at > now());
end;
$$;

revoke all on function set_analytics_opt_in(boolean) from public;
revoke all on function my_post_stats() from public;
grant execute on function set_analytics_opt_in(boolean) to authenticated;
grant execute on function my_post_stats() to authenticated;
