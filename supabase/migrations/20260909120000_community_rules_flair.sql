-- Peak — Phase 4-3a: rules shown on join + member flair.

create table community_rule (
  community_id uuid not null references community (id) on delete cascade,
  position     int not null,
  title        text not null check (char_length(title) between 1 and 100),
  body         text not null default '' check (char_length(body) <= 1000),
  primary key (community_id, position)
);

alter table community_rule enable row level security;
create policy community_rule_select on community_rule for select using (
  exists (select 1 from community c
          where c.id = community_id and can_view_community(c, auth.uid()))
);
-- writes via set_community_rules only

create or replace function community_rules(p_community_id uuid)
returns table (ord int, title text, body text)
language sql stable security definer set search_path = public as $$
  select cr.position, cr.title, cr.body
  from community_rule cr
  join community c on c.id = cr.community_id
  where cr.community_id = p_community_id and can_view_community(c, auth.uid())
  order by cr.position;
$$;

-- admins replace the whole rule set; p_rules is [{title, body}]
create or replace function set_community_rules(p_community_id uuid, p_rules jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare r jsonb; i int := 0;
begin
  if community_role_of(p_community_id, auth.uid()) <> 'admin' then
    raise exception 'only an admin can set the rules';
  end if;
  delete from community_rule where community_id = p_community_id;
  for r in select * from jsonb_array_elements(coalesce(p_rules, '[]'::jsonb)) loop
    if btrim(coalesce(r->>'title', '')) <> '' then
      insert into community_rule (community_id, position, title, body)
      values (p_community_id, i, btrim(r->>'title'),
              left(coalesce(btrim(r->>'body'), ''), 1000));
      i := i + 1;
    end if;
  end loop;
  perform _mod_log(p_community_id, 'edit_settings');
end;
$$;

-- a member sets their own flair (community_member has no direct-write policy)
create or replace function set_my_flair(p_community_id uuid, p_flair text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update community_member
  set flair = nullif(btrim(p_flair), '')
  where community_id = p_community_id
    and member_id = auth.uid() and state = 'active';
  if not found then raise exception 'not an active member'; end if;
end;
$$;

revoke all on function community_rules(uuid)              from public;
revoke all on function set_community_rules(uuid, jsonb)   from public;
revoke all on function set_my_flair(uuid, text)           from public;
grant execute on function community_rules(uuid)            to authenticated;
grant execute on function set_community_rules(uuid, jsonb) to authenticated;
grant execute on function set_my_flair(uuid, text)         to authenticated;

-- ── community_feed carries the author's flair ───────────────────────────
drop function if exists community_feed(uuid, timestamptz, int);
create or replace function community_feed(
  p_community_id uuid,
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
  title text, long_form boolean, is_pinned boolean,
  label text, label_note text, author_flair text
)
language sql stable security definer set search_path = public as $$
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
    p.title, p.long_form, false,
    pl.label, pl.note,
    (select cm.flair from community_member cm
     where cm.community_id = p_community_id and cm.member_id = p.author_id)
  from post p
  join profile a on a.id = p.author_id
  left join post_label pl on pl.post_id = p.id
  where p.community_id = p_community_id
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by p.created_at desc
  limit least(p_limit, 100);
$$;
