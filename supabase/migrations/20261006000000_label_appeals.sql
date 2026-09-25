-- A person can ask a labeler to reconsider a label on their own post.
-- The labeler should answer within 7 days. Upholding an appeal removes
-- the label. Counts are aggregate and name nobody.

create table label_appeal (
  id            uuid primary key default gen_random_uuid(),
  labeler_id    uuid not null,
  post_id       uuid not null,
  appellant_id  uuid not null references profile (id) on delete cascade,
  reason        text not null check (char_length(reason) between 1 and 500),
  status        text not null default 'open'
                  check (status in ('open', 'upheld', 'rejected')),
  response      text check (response is null or char_length(response) <= 500),
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz,
  foreign key (labeler_id, post_id)
    references content_label (labeler_id, post_id) on delete cascade,
  unique (labeler_id, post_id)
);

alter table label_appeal enable row level security;

create or replace function file_label_appeal(
  p_labeler_id uuid, p_post_id uuid, p_reason text
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not exists (
    select 1 from post
    where id = p_post_id and author_id = auth.uid()
  ) then
    raise exception 'not your post';
  end if;
  if not exists (
    select 1 from content_label
    where labeler_id = p_labeler_id and post_id = p_post_id
  ) then
    raise exception 'no label on that post';
  end if;
  insert into label_appeal (labeler_id, post_id, appellant_id, reason)
  values (p_labeler_id, p_post_id, auth.uid(), btrim(p_reason))
  on conflict (labeler_id, post_id) do update
    set reason = excluded.reason
    where label_appeal.status = 'open'
  returning id into v_id;
  if v_id is null then
    raise exception 'an appeal on that label is already decided';
  end if;
  return v_id;
end;
$$;

create or replace function my_content_labels()
returns table (
  labeler_id uuid,
  labeler_name text,
  post_id uuid,
  label_key text,
  label_name text,
  note text,
  appeal_status text
)
language sql stable security definer set search_path = public as $$
  select
    cl.labeler_id,
    l.name,
    cl.post_id,
    cl.label_key,
    ll.name,
    cl.note,
    a.status
  from content_label cl
  join labeler l on l.id = cl.labeler_id
  join labeler_label ll
    on ll.labeler_id = cl.labeler_id and ll.key = cl.label_key
  join post p on p.id = cl.post_id
  left join label_appeal a
    on a.labeler_id = cl.labeler_id and a.post_id = cl.post_id
  where p.author_id = auth.uid()
  order by cl.created_at desc;
$$;

create or replace function labeler_appeal_queue()
returns table (
  id uuid,
  labeler_id uuid,
  labeler_name text,
  post_id uuid,
  reason text,
  created_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select a.id, a.labeler_id, l.name, a.post_id, a.reason, a.created_at
  from label_appeal a
  join labeler l on l.id = a.labeler_id
  where l.owner_id = auth.uid()
    and a.status = 'open'
  order by a.created_at;
$$;

create or replace function resolve_label_appeal(
  p_appeal_id uuid, p_status text, p_response text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_labeler uuid;
  v_post uuid;
begin
  if p_status not in ('upheld', 'rejected') then
    raise exception 'status must be upheld or rejected';
  end if;
  select a.labeler_id, a.post_id into v_labeler, v_post
  from label_appeal a
  join labeler l on l.id = a.labeler_id
  where a.id = p_appeal_id
    and a.status = 'open'
    and l.owner_id = auth.uid();
  if v_labeler is null then
    raise exception 'appeal not open or not yours';
  end if;
  update label_appeal
    set status = p_status,
        response = nullif(btrim(p_response), ''),
        resolved_at = now()
    where id = p_appeal_id;
  if p_status = 'upheld' then
    delete from content_label
    where labeler_id = v_labeler and post_id = v_post;
  end if;
end;
$$;

create or replace function label_transparency()
returns table (
  labels_applied bigint,
  appeals_opened bigint,
  appeals_upheld bigint,
  appeals_rejected bigint,
  appeals_open bigint
)
language sql stable security definer set search_path = public as $$
  select
    (select count(*) from content_label
      where created_at > now() - interval '90 days'),
    (select count(*) from label_appeal
      where created_at > now() - interval '90 days'),
    (select count(*) from label_appeal
      where status = 'upheld' and resolved_at > now() - interval '90 days'),
    (select count(*) from label_appeal
      where status = 'rejected' and resolved_at > now() - interval '90 days'),
    (select count(*) from label_appeal where status = 'open');
$$;

revoke all on function file_label_appeal(uuid, uuid, text) from public, anon;
revoke all on function my_content_labels() from public, anon;
revoke all on function labeler_appeal_queue() from public, anon;
revoke all on function resolve_label_appeal(uuid, text, text) from public, anon;
revoke all on function label_transparency() from public, anon;
grant execute on function file_label_appeal(uuid, uuid, text) to authenticated;
grant execute on function my_content_labels() to authenticated;
grant execute on function labeler_appeal_queue() to authenticated;
grant execute on function resolve_label_appeal(uuid, text, text) to authenticated;
grant execute on function label_transparency() to authenticated;
