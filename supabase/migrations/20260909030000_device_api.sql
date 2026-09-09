-- Peak — Phase 2.5-2: device registration + key-package pool API.
--
-- The `device` / `key_package` tables landed in 2.5-0. This migration gives
-- them a usable RPC surface. On its own — before any MLS content encryption —
-- it powers the "active devices" security screen (Settings → Devices): every
-- app install registers a device row with a long-lived Ed25519 signature key,
-- and the account owner can see, rename, and revoke them.
--
-- All functions run SECURITY INVOKER: the existing RLS policies on `device` and
-- `key_package` already scope every operation to the calling account, so there
-- is nothing to elevate.

-- ── register_device ────────────────────────────────────────────────────────
-- Register (or re-attach) this install as a device of the current account.
-- The signature key is passed as a lowercase hex string (unambiguous over
-- JSON). Idempotent on (account_id, public_sig_key): a reinstall that kept its
-- key gets the same row back, un-revoked, with a fresh last_seen_at.
create or replace function register_device(
  p_public_sig_key text,
  p_label text default null
) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_me  uuid := auth.uid();
  v_id  uuid;
  v_lbl text  := nullif(btrim(p_label), '');
  v_key bytea;
begin
  if v_me is null then raise exception 'not authenticated'; end if;
  if p_public_sig_key is null or p_public_sig_key = '' then
    raise exception 'public_sig_key required';
  end if;
  v_key := decode(p_public_sig_key, 'hex');

  select id into v_id from device
  where account_id = v_me and public_sig_key = v_key;

  if v_id is null then
    insert into device (account_id, public_sig_key, label)
    values (v_me, v_key, v_lbl)
    returning id into v_id;
  else
    update device
      set revoked_at   = null,
          last_seen_at = now(),
          label        = coalesce(v_lbl, label)
      where id = v_id;
  end if;

  return v_id;
end;
$$;

-- ── touch_device ───────────────────────────────────────────────────────────
-- Cheap "I'm still here" ping; the client calls this on launch.
create or replace function touch_device(p_device_id uuid)
returns void
language sql security invoker set search_path = public as $$
  update device set last_seen_at = now()
  where id = p_device_id and account_id = auth.uid();
$$;

-- ── rename_device ──────────────────────────────────────────────────────────
create or replace function rename_device(p_device_id uuid, p_label text)
returns void
language sql security invoker set search_path = public as $$
  update device set label = nullif(btrim(p_label), '')
  where id = p_device_id and account_id = auth.uid();
$$;

-- ── revoke_device ──────────────────────────────────────────────────────────
-- Mark a device revoked and burn its unclaimed key packages so no new
-- conversation adds it. Existing MLS groups drop it at their next commit
-- (Phase 2.5-4). Revoking the current device is the client's cue to sign out.
create or replace function revoke_device(p_device_id uuid)
returns void
language plpgsql security invoker set search_path = public as $$
declare
  v_me uuid := auth.uid();
begin
  update device set revoked_at = now()
  where id = p_device_id and account_id = v_me and revoked_at is null;

  delete from key_package
  where device_id = p_device_id and consumed_at is null
    and exists (select 1 from device d
                where d.id = p_device_id and d.account_id = v_me);
end;
$$;

-- ── my_devices ─────────────────────────────────────────────────────────────
-- Everything the Devices screen needs. `unclaimed_packages` is the size of the
-- device's pre-published KeyPackage pool — 0 is normal until Phase 2.5-3.
create or replace function my_devices()
returns table (
  id                 uuid,
  label              text,
  created_at         timestamptz,
  last_seen_at       timestamptz,
  revoked_at         timestamptz,
  unclaimed_packages int
)
language sql security invoker set search_path = public as $$
  select d.id, d.label, d.created_at, d.last_seen_at, d.revoked_at,
         (select count(*)::int from key_package kp
          where kp.device_id = d.id and kp.consumed_at is null)
  from device d
  where d.account_id = auth.uid()
  order by d.revoked_at is not null, d.last_seen_at desc;
$$;

-- ── key-package pool plumbing (used from Phase 2.5-3 on) ────────────────────
-- Append freshly-generated single-use KeyPackages (lowercase hex) for one of
-- my devices.
create or replace function publish_key_packages(
  p_device_id uuid,
  p_packages  text[]
) returns int
language plpgsql security invoker set search_path = public as $$
declare
  v_pkg text;
  v_n   int := 0;
begin
  if not exists (select 1 from device d
                 where d.id = p_device_id and d.account_id = auth.uid()) then
    raise exception 'not your device';
  end if;

  foreach v_pkg in array coalesce(p_packages, '{}') loop
    insert into key_package (device_id, data) values (p_device_id, decode(v_pkg, 'hex'));
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

-- How many unconsumed packages this device still has — the client replenishes
-- when it drops below a threshold.
create or replace function key_package_pool(p_device_id uuid)
returns int
language sql security invoker set search_path = public as $$
  select count(*)::int from key_package kp
  where kp.device_id = p_device_id
    and kp.consumed_at is null
    and exists (select 1 from device d
                where d.id = p_device_id and d.account_id = auth.uid());
$$;

revoke all on function register_device(text, text)        from public;
revoke all on function touch_device(uuid)                 from public;
revoke all on function rename_device(uuid, text)          from public;
revoke all on function revoke_device(uuid)                from public;
revoke all on function my_devices()                       from public;
revoke all on function publish_key_packages(uuid, text[]) from public;
revoke all on function key_package_pool(uuid)             from public;

grant execute on function register_device(text, text)        to authenticated;
grant execute on function touch_device(uuid)                 to authenticated;
grant execute on function rename_device(uuid, text)          to authenticated;
grant execute on function revoke_device(uuid)                to authenticated;
grant execute on function my_devices()                       to authenticated;
grant execute on function publish_key_packages(uuid, text[]) to authenticated;
grant execute on function key_package_pool(uuid)             to authenticated;
