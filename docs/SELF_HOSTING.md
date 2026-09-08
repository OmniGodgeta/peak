# Self-hosting Peak

The reference instance (**peak.social**) runs the open-source Supabase stack on the
`shadow` box — not hosted Supabase. This document is the runbook.

> Status: not yet stood up. This is the plan; steps get checked off as they're done.

## What runs

| Component | Role |
|---|---|
| Postgres 15+ | the database + RLS (the real authorization boundary) |
| GoTrue | auth (passkeys, email, OAuth) |
| PostgREST | REST over the schema |
| Realtime | feed / chat / notification streams |
| Storage API + S3-compatible store | media (MinIO locally, or a real bucket) |
| Kong | API gateway / routing |
| Studio | admin UI (LAN-only, never public) |
| Edge Runtime (Deno) | `publish`, `media`, `push`, … functions |

## Bring-up (local / `shadow`)

```bash
# 1. Get the Supabase self-host compose bundle (pinned)
git clone --depth 1 https://github.com/supabase/supabase
cp -r supabase/docker peak-instance && cd peak-instance
cp .env.example .env

# 2. Generate secrets — do NOT ship the example values
#    POSTGRES_PASSWORD, JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY,
#    DASHBOARD_PASSWORD, SECRET_KEY_BASE, VAULT_ENC_KEY
#    (JWT keys: https://supabase.com/docs/guides/self-hosting#api-keys)

# 3. Point it at our schema
#    - drop Peak's supabase/migrations/*.sql into ./volumes/db/init or run them
#      via `psql` after start
#    - copy Peak's supabase/functions/* into ./volumes/functions

docker compose up -d
```

Then apply migrations with the Supabase CLI against the running instance:

```bash
cd /path/to/peak/supabase
supabase link --project-ref <n/a for self-host — use db URL>
supabase db push --db-url "postgresql://postgres:<pw>@shadow:5432/postgres"
```

## Networking

- Studio + Postgres: **LAN / tailnet only.** Never expose port 5432 or 8000-studio.
- Public API (Kong, port 8000 → 443): behind TLS via one of
  - **Tailscale Funnel** (already partly configured on `shadow` — see the
    `jellyfin-setup` / `arcade-server` notes), or
  - **Cloudflare Tunnel** (`cloudflared`), or
  - a reverse proxy (Caddy/nginx) with a real cert if `shadow` gets a public IP.
- `peak.social` DNS: A/AAAA or CNAME to whichever ingress is chosen. **Open question #3.**

## Resource budget

Rough: Postgres ~1 GB, Realtime ~256 MB, the rest ~1.5 GB combined, plus media storage
growth. Budget **4 GB RAM** and a dedicated data volume. `shadow` also runs Jellyfin and
`arcade-server` — confirm headroom (**open question #2**).

## Backups

- `pg_dump` nightly (encrypted) off-box.
- Media store: versioned bucket or `restic` to another disk.
- Test a restore before public sign-ups open.

## App config

Point the app at the instance:

```json
// app/env.json
{
  "SUPABASE_URL": "https://peak.social",
  "SUPABASE_ANON_KEY": "<the self-host ANON_KEY>"
}
```

## Upgrades

Pin the Supabase compose bundle by commit. Upgrade = bump the pin, read their changelog,
`docker compose pull && up -d`, run any new Peak migrations. Never auto-pull `latest`.
