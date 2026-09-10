-- Peak — Phase 5: a directory of public custom feeds + share-by-link.
--
-- Public custom_feeds become discoverable. copy_custom_feed now records where a
-- copy came from so a feed can show how many people picked it up. A share link
-- is just the feed id; custom_feed_meta backs a preview before you add it.

alter table custom_feed
  add column copied_from uuid references custom_feed (id) on delete set null;
create index custom_feed_copied_from on custom_feed (copied_from);

-- carry the source id through a copy
create or replace function copy_custom_feed(p_feed_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_src custom_feed; v_id uuid;
begin
  select * into v_src from custom_feed
  where id = p_feed_id and (owner_id = auth.uid() or is_public);
  if v_src.id is null then raise exception 'feed not found'; end if;
  insert into custom_feed (owner_id, name, rules, is_public, copied_from)
  values (auth.uid(), left(v_src.name || ' (copy)', 60), v_src.rules, false,
          v_src.id)
  returning id into v_id;
  return v_id;
end;
$$;

-- browse public feeds. p_sort: 'popular' (most copied) | 'new'.
create or replace function custom_feeds_browse(
  p_query text default '',
  p_sort  text default 'popular',
  p_limit int default 30
)
returns table (
  id uuid, name text, rules jsonb, owner_handle citext,
  owner_display_name text, copy_count int, mine boolean, added boolean
)
language sql stable security definer set search_path = public as $$
  select
    cf.id, cf.name, cf.rules, o.handle, o.display_name,
    (select count(*)::int from custom_feed c2 where c2.copied_from = cf.id),
    (cf.owner_id = auth.uid()),
    exists (select 1 from custom_feed c3
            where c3.owner_id = auth.uid() and c3.copied_from = cf.id)
  from custom_feed cf
  join profile o on o.id = cf.owner_id
  where cf.is_public
    and (btrim(p_query) = '' or cf.name ilike '%' || btrim(p_query) || '%')
  order by
    case when p_sort = 'new' then cf.created_at end desc nulls last,
    (select count(*) from custom_feed c2 where c2.copied_from = cf.id) desc,
    cf.created_at desc
  limit least(p_limit, 60);
$$;

-- one public feed's metadata, for a share-link preview
create or replace function custom_feed_meta(p_feed_id uuid)
returns table (
  id uuid, name text, rules jsonb, owner_handle citext,
  owner_display_name text, copy_count int, mine boolean, added boolean
)
language sql stable security definer set search_path = public as $$
  select
    cf.id, cf.name, cf.rules, o.handle, o.display_name,
    (select count(*)::int from custom_feed c2 where c2.copied_from = cf.id),
    (cf.owner_id = auth.uid()),
    exists (select 1 from custom_feed c3
            where c3.owner_id = auth.uid() and c3.copied_from = cf.id)
  from custom_feed cf
  join profile o on o.id = cf.owner_id
  where cf.id = p_feed_id and (cf.is_public or cf.owner_id = auth.uid());
$$;

revoke all on function custom_feeds_browse(text, text, int) from public, anon;
revoke all on function custom_feed_meta(uuid)               from public, anon;
grant execute on function custom_feeds_browse(text, text, int) to authenticated;
grant execute on function custom_feed_meta(uuid)               to authenticated;
