-- Peak — Phase 3: data controls.
--
-- Two of the bolded promises in PRODUCT.md §9.2:
--   * Real delete — deleting a post hides it immediately; a 30-day
--     "recently deleted" bin guards against slips; a sweep hard-deletes after.
--   * One-click export — the whole account as a single JSON archive.
--
-- `post.deleted_at` already exists and every feed/thread RPC already skips
-- soft-deleted rows; this adds the owner-facing verbs around it.

-- ── post soft-delete lifecycle ────────────────────────────────────────────

create or replace function delete_post(p_post_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update post set deleted_at = now()
  where id = p_post_id and author_id = auth.uid() and deleted_at is null;
  if not found then raise exception 'post not found'; end if;
end;
$$;

create or replace function restore_post(p_post_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update post set deleted_at = null
  where id = p_post_id and author_id = auth.uid()
    and deleted_at is not null
    and deleted_at > now() - interval '30 days';
  if not found then raise exception 'nothing to restore (already purged?)'; end if;
end;
$$;

-- The bin. `post_select` hides deleted rows even from their author, so this
-- has to be a SECURITY DEFINER RPC.
create or replace function my_deleted_posts()
returns table (
  id uuid,
  body text,
  created_at timestamptz,
  deleted_at timestamptz,
  reply_to uuid,
  media jsonb,
  purges_at timestamptz
)
language sql security definer set search_path = public as $$
  select p.id, p.body, p.created_at, p.deleted_at, p.reply_to,
         post_media_json(p.id),
         p.deleted_at + interval '30 days'
  from post p
  where p.author_id = auth.uid()
    and p.deleted_at is not null
    and p.deleted_at > now() - interval '30 days'
  order by p.deleted_at desc;
$$;

-- Hard-delete everything past the 30-day window. SECURITY DEFINER, no auth
-- check — it only ever touches already-soft-deleted rows. Schedule via pg_cron
-- (ops owns the schedule); also safe to run by hand.
create or replace function purge_expired_deletions()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  with gone as (
    delete from post
    where deleted_at is not null
      and deleted_at < now() - interval '30 days'
    returning 1
  )
  select count(*) into v_n from gone;
  return v_n;
end;
$$;

revoke all on function delete_post(uuid)            from public;
revoke all on function restore_post(uuid)           from public;
revoke all on function my_deleted_posts()           from public;
revoke all on function purge_expired_deletions()    from public;
grant execute on function delete_post(uuid)         to authenticated;
grant execute on function restore_post(uuid)        to authenticated;
grant execute on function my_deleted_posts()        to authenticated;
-- purge_expired_deletions stays service-role / cron only.

-- ── one-click export ──────────────────────────────────────────────────────
-- The caller's whole account as one JSON document. Posts are shaped loosely
-- like ActivityStreams Notes. The `export` Edge Function wraps this, writes it
-- to the private `exports` bucket, and hands back a short-lived signed URL.
create or replace function export_my_data()
returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'peak_export_version', 1,
    'generated_at', now(),

    'account', (
      select to_jsonb(pr)
        || jsonb_build_object(
             'birthdate',
               (select pp.birthdate from profile_private pp where pp.id = auth.uid()),
             'personas',
               (select coalesce(jsonb_agg(to_jsonb(pe) order by pe.created_at), '[]')
                from persona pe where pe.account_id = auth.uid())
           )
      from profile pr where pr.id = auth.uid()
    ),

    'circles', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', c.name,
        'slug', c.slug,
        'system', c.is_system,
        'members', (select coalesce(jsonb_agg(fq_handle(m) order by m.handle), '[]')
                    from circle_member cm join profile m on m.id = cm.member_id
                    where cm.circle_id = c.id)
      ) order by c.sort_order), '[]')
      from circle c where c.owner_id = auth.uid()
    ),

    'graph', jsonb_build_object(
      'following', (select coalesce(jsonb_agg(fq_handle(p) order by p.handle), '[]')
                    from follow f join profile p on p.id = f.followee_id
                    where f.follower_id = auth.uid()),
      'followers', (select coalesce(jsonb_agg(fq_handle(p) order by p.handle), '[]')
                    from follow f join profile p on p.id = f.follower_id
                    where f.followee_id = auth.uid()),
      'blocked',   (select coalesce(jsonb_agg(fq_handle(p) order by p.handle), '[]')
                    from block b join profile p on p.id = b.blocked_id
                    where b.blocker_id = auth.uid()),
      'muted',     (select coalesce(jsonb_agg(fq_handle(p) order by p.handle), '[]')
                    from mute mu join profile p on p.id = mu.muted_id
                    where mu.muter_id = auth.uid()),
      'muted_words', (select coalesce(jsonb_agg(mw.phrase order by mw.phrase), '[]')
                      from mute_word mw where mw.owner_id = auth.uid())
    ),

    'posts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id,
        'type', 'Note',
        'published', p.created_at,
        'updated', p.edited_at,
        'deleted', p.deleted_at,
        'visibility', p.visibility,
        'contentWarning', p.content_warning,
        'sensitive', p.is_sensitive,
        'inReplyTo', p.reply_to,
        'content', p.body,
        'attachment', post_media_json(p.id)
      ) order by p.created_at), '[]')
      from post p where p.author_id = auth.uid()
    ),

    'reactions', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'post', r.post_id, 'kind', r.kind, 'at', r.created_at) order by r.created_at), '[]')
      from reaction r where r.actor_id = auth.uid()
    ),
    'reposts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'post', rp.post_id, 'at', rp.created_at) order by rp.created_at), '[]')
      from repost rp where rp.actor_id = auth.uid()
    ),

    'messages', jsonb_build_object(
      'note', 'Bodies are included for transport-only conversations. '
              'End-to-end encrypted conversations are stored as ciphertext and '
              'are not readable from this archive.',
      'conversations', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', c.id,
          'title', c.title,
          'group', c.is_group,
          'e2ee', c.e2ee,
          'messages', (
            select coalesce(jsonb_agg(jsonb_build_object(
              'mine', msg.sender_id is not distinct from auth.uid(),
              'body', case when c.e2ee then null else msg.body end,
              'at', msg.created_at,
              'edited', msg.edited_at,
              'deleted', msg.deleted_at
            ) order by msg.created_at), '[]')
            from message msg where msg.conversation_id = c.id
          )
        ) order by c.created_at), '[]')
        from conversation c
        where exists (select 1 from conversation_member cm
                      where cm.conversation_id = c.id and cm.member_id = auth.uid())
      )
    ),

    'devices', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'label', d.label,
        'created_at', d.created_at,
        'last_seen_at', d.last_seen_at,
        'revoked_at', d.revoked_at) order by d.created_at), '[]')
      from device d where d.account_id = auth.uid()
    )
  );
$$;

revoke all on function export_my_data()      from public;
grant execute on function export_my_data()   to authenticated;

-- ── exports bucket: private, owner-folder read only ───────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('exports', 'exports', false, 52428800, array['application/json'])
on conflict (id) do nothing;

create policy "exports: read own folder" on storage.objects for select to authenticated
  using (bucket_id = 'exports' and (storage.foldername(name))[1] = auth.uid()::text);
