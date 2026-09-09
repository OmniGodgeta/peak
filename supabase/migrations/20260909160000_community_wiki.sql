-- Peak — Phase 4-5: community wiki + pinned resources.
--
-- Markdown pages that belong to a community. Moderators edit; members read.
-- Every save snapshots a revision so history is inspectable. A page can be
-- pinned to show on the community's front page.

create table community_wiki_page (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references community (id) on delete cascade,
  slug         citext not null check (slug ~ '^[a-z0-9][a-z0-9_-]{1,60}$'),
  title        text not null check (char_length(title) between 1 and 140),
  body         text not null default '' check (char_length(body) <= 50000),
  is_pinned    boolean not null default false,
  updated_by   uuid references profile (id) on delete set null,
  updated_at   timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  unique (community_id, slug)
);
create index community_wiki_page_by_community
  on community_wiki_page (community_id, is_pinned desc, title);

create table community_wiki_revision (
  id         uuid primary key default gen_random_uuid(),
  page_id    uuid not null references community_wiki_page (id) on delete cascade,
  title      text not null,
  body       text not null,
  note       text check (char_length(note) <= 280),
  edited_by  uuid references profile (id) on delete set null,
  edited_at  timestamptz not null default now()
);
create index community_wiki_revision_by_page
  on community_wiki_revision (page_id, edited_at desc);

alter table community_wiki_page     enable row level security;
alter table community_wiki_revision enable row level security;

create policy community_wiki_page_select on community_wiki_page for select using (
  exists (select 1 from community c
          where c.id = community_id and can_view_community(c, auth.uid()))
);
create policy community_wiki_revision_select on community_wiki_revision for select using (
  exists (select 1 from community_wiki_page p
          where p.id = page_id and is_community_member(p.community_id, auth.uid()))
);
-- writes via the RPCs below only

-- ── readers ───────────────────────────────────────────────────────────
create or replace function community_wiki_pages(p_community_id uuid)
returns table (
  id uuid, slug citext, title text, is_pinned boolean,
  updated_at timestamptz, updated_by_handle citext, can_edit boolean
)
language sql stable security definer set search_path = public as $$
  select
    w.id, w.slug, w.title, w.is_pinned, w.updated_at, up.handle,
    community_can_moderate(w.community_id, auth.uid())
  from community_wiki_page w
  join community c on c.id = w.community_id
  left join profile up on up.id = w.updated_by
  where w.community_id = p_community_id and can_view_community(c, auth.uid())
  order by w.is_pinned desc, w.title;
$$;

create or replace function wiki_page(p_community_id uuid, p_slug text)
returns table (
  id uuid, slug citext, title text, body text, is_pinned boolean,
  updated_at timestamptz, updated_by_handle citext, can_edit boolean
)
language sql stable security definer set search_path = public as $$
  select
    w.id, w.slug, w.title, w.body, w.is_pinned, w.updated_at, up.handle,
    community_can_moderate(w.community_id, auth.uid())
  from community_wiki_page w
  join community c on c.id = w.community_id
  left join profile up on up.id = w.updated_by
  where w.community_id = p_community_id
    and w.slug = lower(btrim(p_slug))
    and can_view_community(c, auth.uid());
$$;

create or replace function wiki_page_history(p_page_id uuid, p_limit int default 30)
returns table (
  id uuid, title text, note text, edited_at timestamptz,
  editor_handle citext, editor_display_name text, body text
)
language sql stable security definer set search_path = public as $$
  select
    r.id, r.title, r.note, r.edited_at, e.handle, e.display_name, r.body
  from community_wiki_revision r
  join community_wiki_page p on p.id = r.page_id
  left join profile e on e.id = r.edited_by
  where r.page_id = p_page_id
    and is_community_member(p.community_id, auth.uid())
  order by r.edited_at desc
  limit least(p_limit, 100);
$$;

-- ── writes (moderators) ───────────────────────────────────────────────
create or replace function save_wiki_page(
  p_community_id uuid, p_slug text, p_title text, p_body text,
  p_note text default null
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not community_can_moderate(p_community_id, auth.uid()) then
    raise exception 'only a moderator can edit the wiki';
  end if;

  insert into community_wiki_page
    (community_id, slug, title, body, updated_by, updated_at)
  values (
    p_community_id, lower(btrim(p_slug)), btrim(p_title),
    left(coalesce(p_body, ''), 50000), auth.uid(), now()
  )
  on conflict (community_id, slug) do update
    set title = excluded.title, body = excluded.body,
        updated_by = excluded.updated_by, updated_at = now()
  returning id into v_id;

  insert into community_wiki_revision (page_id, title, body, note, edited_by)
  values (v_id, btrim(p_title), left(coalesce(p_body, ''), 50000),
          nullif(btrim(p_note), ''), auth.uid());

  perform _mod_log(p_community_id, 'edit_settings');
  return v_id;
end;
$$;

create or replace function delete_wiki_page(p_page_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_community uuid;
begin
  select community_id into v_community from community_wiki_page where id = p_page_id;
  if v_community is null then return; end if;
  if not community_can_moderate(v_community, auth.uid()) then
    raise exception 'only a moderator can delete a wiki page';
  end if;
  delete from community_wiki_page where id = p_page_id;
  perform _mod_log(v_community, 'edit_settings');
end;
$$;

create or replace function set_wiki_pinned(p_page_id uuid, p_pinned boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_community uuid;
begin
  select community_id into v_community from community_wiki_page where id = p_page_id;
  if v_community is null then raise exception 'no such page'; end if;
  if not community_can_moderate(v_community, auth.uid()) then
    raise exception 'only a moderator can pin a wiki page';
  end if;
  update community_wiki_page set is_pinned = p_pinned where id = p_page_id;
end;
$$;

revoke all on function community_wiki_pages(uuid)                    from public;
revoke all on function wiki_page(uuid, text)                         from public;
revoke all on function wiki_page_history(uuid, int)                  from public;
revoke all on function save_wiki_page(uuid, text, text, text, text)  from public;
revoke all on function delete_wiki_page(uuid)                        from public;
revoke all on function set_wiki_pinned(uuid, boolean)                from public;
grant execute on function community_wiki_pages(uuid)                  to authenticated;
grant execute on function wiki_page(uuid, text)                       to authenticated;
grant execute on function wiki_page_history(uuid, int)                to authenticated;
grant execute on function save_wiki_page(uuid, text, text, text, text) to authenticated;
grant execute on function delete_wiki_page(uuid)                      to authenticated;
grant execute on function set_wiki_pinned(uuid, boolean)              to authenticated;
