-- Peak — Phase 3: profile highlights (pinned posts).
--
-- Pin up to 5 of your own posts to the top of your profile. This is the
-- "shelves / highlights" idea in its simplest honest form — no separate
-- curated albums, just the posts you want a visitor to see first.

create table profile_pin (
  owner_id   uuid not null references profile (id) on delete cascade,
  post_id    uuid not null references post (id) on delete cascade,
  sort_order int not null default 0,
  pinned_at  timestamptz not null default now(),
  primary key (owner_id, post_id)
);

alter table profile_pin enable row level security;

-- The row just says "X pinned Y"; whether a viewer can *see* post Y is still
-- decided by can_view_post inside posts_by. So the row itself is public.
create policy profile_pin_select on profile_pin for select using (true);
create policy profile_pin_write on profile_pin for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function pin_post(p_post_id uuid)
returns void
language plpgsql security invoker set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if not exists (
    select 1 from post
    where id = p_post_id and author_id = v_me
      and deleted_at is null and reply_to is null
  ) then
    raise exception 'you can only pin your own top-level posts';
  end if;

  if not exists (select 1 from profile_pin where owner_id = v_me and post_id = p_post_id)
     and (select count(*) from profile_pin where owner_id = v_me) >= 5 then
    raise exception 'you can pin up to 5 posts';
  end if;

  insert into profile_pin (owner_id, post_id, sort_order)
  values (
    v_me, p_post_id,
    coalesce((select max(sort_order) + 1 from profile_pin where owner_id = v_me), 0)
  )
  on conflict (owner_id, post_id) do nothing;
end;
$$;

create or replace function unpin_post(p_post_id uuid)
returns void
language sql security invoker set search_path = public as $$
  delete from profile_pin where owner_id = auth.uid() and post_id = p_post_id;
$$;

revoke all on function pin_post(uuid)   from public;
revoke all on function unpin_post(uuid) from public;
grant execute on function pin_post(uuid)   to authenticated;
grant execute on function unpin_post(uuid) to authenticated;

-- posts_by now also says whether each post is pinned by its author, so the
-- profile screen can float pinned posts to the top.
drop function if exists posts_by(uuid, timestamptz, int);
create or replace function posts_by(
  p_author uuid, p_before timestamptz default now(), p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, is_pinned boolean
)
language sql stable as $$
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    exists (select 1 from profile_pin pp
            where pp.owner_id = p_author and pp.post_id = p.id)
  from post p
  join profile a on a.id = p.author_id
  where p.author_id = p_author
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
  order by p.created_at desc
  limit least(p_limit, 100);
$$;
