# Running & administering Peak

Where Peak keeps data, what the keys are, and how to operate it. Written for
the person running the instance, not for contributors (see ARCHITECTURE.md for
that).

> Status: **local dev only.** Everything below is on one machine; nothing is
> reachable from outside it. The hosted picture (Stage 2) is a note at the end.

---

## Where everything lives

| What | Where (local dev) |
|---|---|
| The entire database | Docker volume `supabase_db_peak` → `/var/lib/docker/volumes/supabase_db_peak/_data`. A full PostgreSQL server in a container. |
| Uploaded media (avatars, post photos/GIFs) | Docker volume for the storage container (S3-compatible store, `post-media` bucket) |
| Backend config | `supabase/config.toml` |
| Schema history | `supabase/migrations/*.sql` (the source of truth — the DB is rebuilt from these) |
| Android signing key | `~/.android/peak-release.jks`; passwords in `~/.config/peak/android-keystore.txt`; base64 copy in GitHub Actions secrets |

The stack runs as containers: `supabase_db_peak`, `_auth_`, `_rest_`, `_storage_`,
`_kong_` (gateway), `_studio_`, `_realtime_`, `_edge_runtime_`, `_inbucket_` (mail),
`_analytics_`, `_vector_`. Start/stop:

```bash
cd ~/Work/peak/supabase
supabase start      # needs docker group — run `newgrp docker` first if a fresh shell
supabase stop       # leaves the volume intact
supabase stop --no-backup && supabase start   # only if you want a clean slate
```

---

## The data

### Accounts & credentials — `auth` schema (managed by GoTrue)

| Table | Holds |
|---|---|
| `auth.users` | one row per account: id, email, **bcrypt password hash** (`$2a$…`, not reversible), timestamps, confirmation state |
| `auth.identities` | linked OAuth / social logins |
| `auth.sessions`, `auth.refresh_tokens` | active logins |
| `auth.mfa_factors`, `auth.webauthn_credentials` | TOTP and passkeys |
| `auth.audit_log_entries` | auth events (sign-in, password change, …) |

Passwords are never stored or recoverable in plaintext — not even by you. To
help a locked-out user you send a reset, you don't read their password.

### App data — `public` schema (Row-Level Security on every table)

`profile`, `profile_private` (email, birthdate, derived teen/adult), `persona`,
`circle`, `circle_member`, `follow`, `block`, `mute`, `mute_word`, `post`,
`post_audience`, `post_media`, `mention`, `reaction`, `repost`, and
`app_release` (the updater manifest).

RLS is the real authorization boundary — the API trusts the database, not the
client. Key helper functions: `blocked_between`, `can_view_post`,
`kind_for_birthdate`, `enforce_teen_defaults`. Onboarding goes through the
`bootstrap_account` RPC (enforces the 13+ floor and creates the five starting
circles).

---

## The keys

| Key | Purpose | Local value | Where it is |
|---|---|---|---|
| **anon key** | public client key; safe to ship in the app (RLS still applies) | Supabase **demo value**, identical on every dev machine | `app/env.json`, baked into the APK at build |
| **service_role key** | bypasses RLS — the "admin API key" for scripts | demo value | inside the containers / `supabase status` |
| **JWT secret** | signs session tokens | demo value | inside the containers |
| **Postgres password** | direct DB access | `postgres` | — |

The first three are **not secret in local dev** — they're well-known fixtures.
Hosted Supabase generates real, unique values (Stage 2); those go in GitHub
Actions secrets / the host env, never the repo.

Android signing (real, already generated): losing `peak-release.jks` means you
can never ship an update to an already-installed build — **back it up offline.**

---

## Admin surfaces (all localhost only)

| Tool | URL / DSN | Use for |
|---|---|---|
| **Supabase Studio** | `http://localhost:54323` | the main console: table editor, SQL editor, and **Authentication** (list / create / delete / ban users, send password resets), logs, storage browser |
| **Postgres (direct)** | `postgresql://postgres:postgres@localhost:54322/postgres` | `psql`, DBeaver, TablePlus — anything Studio can't do |
| **Mailpit** | `http://localhost:54324` | every email the app "sends" (confirmations, resets) lands here — there's no real mail server locally |
| **API gateway** | `http://localhost:54321` | REST (`/rest/v1`), auth (`/auth/v1`), functions (`/functions/v1`) |

---

## Common tasks

```bash
# Snapshot the database before anything risky
supabase db dump --local -f ~/peak-backup-$(date +%F).sql

# Rebuild the DB from migrations + seed (WIPES all local data, incl. users)
supabase db reset

# Apply only new migrations, keep data
supabase migration up

# Open a SQL shell
psql postgresql://postgres:postgres@localhost:54322/postgres
```

In SQL (or the Studio SQL editor):

```sql
-- who exists
select id, email, created_at, last_sign_in_at from auth.users order by created_at desc;

-- a user's profile + private fields
select * from profile p join profile_private pv on pv.id = p.id where p.handle = 'someone';

-- ban: block sign-in without deleting anything
update auth.users set banned_until = 'infinity' where email = 'abuser@example.com';
-- …and lift it
update auth.users set banned_until = null where email = 'abuser@example.com';

-- hard delete a user (cascades to their profile/posts via FKs)
-- prefer Studio → Authentication → delete, which does this cleanly
delete from auth.users where id = '<uuid>';
```

Auth policy (min password length, email confirmation on/off, signup open/closed)
lives in `supabase/config.toml` under `[auth]` and `[auth.email]`; change it and
restart the stack.

---

## What does not exist yet

- **No in-app moderation.** There is no admin/moderator role in the schema, no
  report queue, no "ban from inside Peak" button. Today moderation = you, in
  Studio / SQL. Building this (roles, reports, audit trail, a takedown flow) is
  a hard requirement before a public launch — see [DEPLOY.md](DEPLOY.md) §6.
- **No automatic backups** of the local database — only the manual
  `supabase db dump` above.
- **No rate-limit / abuse tooling** beyond what GoTrue does by default.

---

## Stage 2 — hosted

When Peak moves to hosted Supabase (see [DEPLOY.md](DEPLOY.md)):

- The database and storage move to Supabase's servers — still **your** project,
  same Studio UI at `supabase.com`, with **automatic daily backups** and
  point-in-time recovery on the Pro plan.
- Real unique keys replace the demo ones; the `service_role` key becomes a
  genuine secret.
- Email stops going to Mailpit and goes through a real provider (Resend / SES).
- Nothing about the schema changes — it's `supabase db push` plus a config swap.
- Administration is the same Studio surface plus the `supabase` CLI against the
  linked project.
