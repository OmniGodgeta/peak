-- Peak — Phase 5: user-level labelers (stackable, subscribable).
--
-- A labeler is a user-run labelling service. Its owner defines a set of labels
-- (each with a severity) and applies them to posts. Other people subscribe to
-- the labelers they trust; the app then shows those labels on posts and, for a
-- 'hide' severity, blurs the post behind a click-through. Nothing here removes
-- content — labels are additive and always attributed to their labeler.

create type label_severity as enum ('info', 'warn', 'hide');

create table labeler (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references profile (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 60),
  description text not null default '' check (char_length(description) <= 500),
  is_public   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index labeler_by_owner on labeler (owner_id);

create table labeler_label (
  labeler_id uuid not null references labeler (id) on delete cascade,
  key        text not null check (key ~ '^[a-z0-9][a-z0-9-]{0,38}$'),
  name       text not null check (char_length(name) between 1 and 60),
  severity   label_severity not null default 'info',
  primary key (labeler_id, key)
);

create table content_label (
  labeler_id uuid not null references labeler (id) on delete cascade,
  post_id    uuid not null references post (id) on delete cascade,
  label_key  text not null,
  note       text check (char_length(note) <= 280),
  created_by uuid references profile (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (labeler_id, post_id),
  foreign key (labeler_id, label_key) references labeler_label (labeler_id, key)
    on delete cascade
);
create index content_label_by_post on content_label (post_id);

create table labeler_subscription (
  subscriber_id uuid not null references profile (id) on delete cascade,
  labeler_id    uuid not null references labeler (id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (subscriber_id, labeler_id)
);

alter table labeler              enable row level security;
alter table labeler_label        enable row level security;
alter table content_label        enable row level security;
alter table labeler_subscription enable row level security;

create policy labeler_select on labeler for select
  using (is_public or owner_id = auth.uid());
create policy labeler_write on labeler for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy labeler_label_select on labeler_label for select using (
  exists (select 1 from labeler l where l.id = labeler_id
          and (l.is_public or l.owner_id = auth.uid()))
);
create policy labeler_label_write on labeler_label for all using (
  exists (select 1 from labeler l where l.id = labeler_id and l.owner_id = auth.uid())
) with check (
  exists (select 1 from labeler l where l.id = labeler_id and l.owner_id = auth.uid())
);

-- a content_label is visible to the labeler's owner, its subscribers, and the
-- labelled post's author (so they can see/appeal it)
create policy content_label_select on content_label for select using (
  exists (select 1 from labeler l where l.id = labeler_id and l.owner_id = auth.uid())
  or exists (select 1 from labeler_subscription s
             where s.labeler_id = content_label.labeler_id and s.subscriber_id = auth.uid())
  or exists (select 1 from post p where p.id = post_id and p.author_id = auth.uid())
);
create policy content_label_write on content_label for all using (
  exists (select 1 from labeler l where l.id = labeler_id and l.owner_id = auth.uid())
) with check (
  exists (select 1 from labeler l where l.id = labeler_id and l.owner_id = auth.uid())
);

create policy labeler_subscription_own on labeler_subscription for all
  using (subscriber_id = auth.uid()) with check (subscriber_id = auth.uid());

-- ── RPCs ──────────────────────────────────────────────────────────────
create or replace function create_labeler(
  p_name text, p_description text default '', p_public boolean default true
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into labeler (owner_id, name, description, is_public)
  values (auth.uid(), btrim(p_name), coalesce(btrim(p_description), ''), p_public)
  returning id into v_id;
  return v_id;
end;
$$;

-- replace a labeler's label set; p_labels is [{key, name, severity}]
create or replace function set_labeler_labels(p_labeler_id uuid, p_labels jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare l jsonb;
begin
  if not exists (select 1 from labeler where id = p_labeler_id and owner_id = auth.uid()) then
    raise exception 'not your labeler';
  end if;
  delete from labeler_label where labeler_id = p_labeler_id
    and key not in (select x->>'key' from jsonb_array_elements(coalesce(p_labels,'[]'::jsonb)) x);
  for l in select * from jsonb_array_elements(coalesce(p_labels, '[]'::jsonb)) loop
    if l->>'key' ~ '^[a-z0-9][a-z0-9-]{0,38}$' then
      insert into labeler_label (labeler_id, key, name, severity)
      values (p_labeler_id, l->>'key', btrim(l->>'name'),
              coalesce((l->>'severity')::label_severity, 'info'))
      on conflict (labeler_id, key) do update
        set name = excluded.name, severity = excluded.severity;
    end if;
  end loop;
end;
$$;

create or replace function apply_content_label(
  p_labeler_id uuid, p_post_id uuid, p_label_key text, p_note text default null
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from labeler where id = p_labeler_id and owner_id = auth.uid()) then
    raise exception 'not your labeler';
  end if;
  if not exists (select 1 from labeler_label
                 where labeler_id = p_labeler_id and key = p_label_key) then
    raise exception 'no such label on this labeler';
  end if;
  insert into content_label (labeler_id, post_id, label_key, note, created_by)
  values (p_labeler_id, p_post_id, p_label_key, nullif(btrim(p_note), ''), auth.uid())
  on conflict (labeler_id, post_id) do update
    set label_key = excluded.label_key, note = excluded.note, created_at = now();
end;
$$;

create or replace function remove_content_label(p_labeler_id uuid, p_post_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from labeler where id = p_labeler_id and owner_id = auth.uid()) then
    raise exception 'not your labeler';
  end if;
  delete from content_label where labeler_id = p_labeler_id and post_id = p_post_id;
end;
$$;

create or replace function subscribe_labeler(p_labeler_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from labeler where id = p_labeler_id
                 and (is_public or owner_id = auth.uid())) then
    raise exception 'labeler not available';
  end if;
  insert into labeler_subscription (subscriber_id, labeler_id)
  values (auth.uid(), p_labeler_id) on conflict do nothing;
end;
$$;

create or replace function unsubscribe_labeler(p_labeler_id uuid)
returns void
language sql security definer set search_path = public as $$
  delete from labeler_subscription
  where subscriber_id = auth.uid() and labeler_id = p_labeler_id;
$$;

create or replace function my_labelers()
returns table (
  id uuid, name text, description text, is_public boolean, owned boolean,
  subscribed boolean, label_count int, applied_count int
)
language sql stable security definer set search_path = public as $$
  select
    l.id, l.name, l.description, l.is_public,
    (l.owner_id = auth.uid()),
    exists (select 1 from labeler_subscription s
            where s.labeler_id = l.id and s.subscriber_id = auth.uid()),
    (select count(*)::int from labeler_label ll where ll.labeler_id = l.id),
    (select count(*)::int from content_label cl where cl.labeler_id = l.id)
  from labeler l
  where l.owner_id = auth.uid()
     or exists (select 1 from labeler_subscription s
                where s.labeler_id = l.id and s.subscriber_id = auth.uid())
  order by (l.owner_id = auth.uid()) desc, l.name;
$$;

create or replace function labelers_browse(p_query text default '', p_limit int default 30)
returns table (
  id uuid, name text, description text, owner_handle citext,
  subscriber_count int, subscribed boolean
)
language sql stable security definer set search_path = public as $$
  select
    l.id, l.name, l.description, o.handle,
    (select count(*)::int from labeler_subscription s where s.labeler_id = l.id),
    exists (select 1 from labeler_subscription s
            where s.labeler_id = l.id and s.subscriber_id = auth.uid())
  from labeler l
  join profile o on o.id = l.owner_id
  where l.is_public
    and (btrim(p_query) = '' or l.name ilike '%' || btrim(p_query) || '%')
  order by (select count(*) from labeler_subscription s where s.labeler_id = l.id) desc,
           l.created_at desc
  limit least(p_limit, 60);
$$;

create or replace function labeler_labels(p_labeler_id uuid)
returns table (key text, name text, severity label_severity)
language sql stable security definer set search_path = public as $$
  select ll.key, ll.name, ll.severity
  from labeler_label ll
  join labeler l on l.id = ll.labeler_id
  where ll.labeler_id = p_labeler_id
    and (l.is_public or l.owner_id = auth.uid())
  order by ll.severity desc, ll.name;
$$;

-- the labels the caller should see on a batch of posts (from labelers they
-- subscribe to, plus their own labelers). Ordered so the app can pick the
-- highest severity per post.
create or replace function post_labels_for_me(p_post_ids uuid[])
returns table (
  post_id uuid, labeler_id uuid, labeler_name text,
  label_key text, label_name text, severity label_severity, note text
)
language sql stable security definer set search_path = public as $$
  select
    cl.post_id, cl.labeler_id, l.name,
    cl.label_key, ll.name, ll.severity, cl.note
  from content_label cl
  join labeler l on l.id = cl.labeler_id
  join labeler_label ll on ll.labeler_id = cl.labeler_id and ll.key = cl.label_key
  where cl.post_id = any (p_post_ids)
    and (
      l.owner_id = auth.uid()
      or exists (select 1 from labeler_subscription s
                 where s.labeler_id = cl.labeler_id and s.subscriber_id = auth.uid())
    )
  order by cl.post_id,
    array_position(array['hide','warn','info']::label_severity[], ll.severity);
$$;

revoke all on function create_labeler(text, text, boolean)            from public, anon;
revoke all on function set_labeler_labels(uuid, jsonb)                from public, anon;
revoke all on function apply_content_label(uuid, uuid, text, text)    from public, anon;
revoke all on function remove_content_label(uuid, uuid)               from public, anon;
revoke all on function subscribe_labeler(uuid)                        from public, anon;
revoke all on function unsubscribe_labeler(uuid)                      from public, anon;
revoke all on function my_labelers()                                  from public, anon;
revoke all on function labelers_browse(text, int)                     from public, anon;
revoke all on function labeler_labels(uuid)                           from public, anon;
revoke all on function post_labels_for_me(uuid[])                     from public, anon;
grant execute on function create_labeler(text, text, boolean)          to authenticated;
grant execute on function set_labeler_labels(uuid, jsonb)              to authenticated;
grant execute on function apply_content_label(uuid, uuid, text, text)  to authenticated;
grant execute on function remove_content_label(uuid, uuid)            to authenticated;
grant execute on function subscribe_labeler(uuid)                      to authenticated;
grant execute on function unsubscribe_labeler(uuid)                    to authenticated;
grant execute on function my_labelers()                                to authenticated;
grant execute on function labelers_browse(text, int)                   to authenticated;
grant execute on function labeler_labels(uuid)                         to authenticated;
grant execute on function post_labels_for_me(uuid[])                   to authenticated;
