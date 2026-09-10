# Stand up the hosted backend (no domain yet)

> **Status (2026-09-10): DONE.** Project `izvcozvfqmggyziaeeoc` is live — all
> migrations applied, pg_cron jobs scheduled, edge functions deployed, and the
> Tailscale preview web points at it. What's left: the two **you** items below
> (Auth URL config; the APK tag), then a domain + public web host.

The plan: run Peak's backend on **hosted Supabase** now, keep using the Tailscale
preview URL for the web app, and defer `peak.social` + the public web host until
the domain is registered. When you're ready for a domain, pick up
[DEPLOY.md](DEPLOY.md) §1–2 and §5.

Everything in **step 1** is on you (it needs your Supabase account). From
**step 2** on, hand the commands to this session with `! <command>` in the
prompt, or run `scripts/deploy-hosted.sh` after exporting the two variables it
names.

---

## 1. Create the project — you

1. <https://supabase.com/dashboard> → **New project**.
   - **Region**: closest to you / your testers. *Permanent* — can't move it later.
   - **Database password**: generate one, save it in your password manager.
   - Free tier is fine to start. (Pro, $25/mo, gets daily backups + no auto-pause —
     worth it before real traffic, not before.)
2. Wait for it to provision (~2 min).
3. **Project Settings → API** — copy these four values somewhere safe:
   | | looks like |
   |---|---|
   | Project ref | `abcdefghijklmnop` (also in the URL) |
   | Project URL | `https://abcdefghijklmnop.supabase.co` |
   | `anon` key | `eyJ…` (long; safe to ship in the app — RLS is the boundary) |
   | `service_role` key | `eyJ…` (**secret** — never in the repo or the client) |
4. **Account → Access Tokens** → generate a CLI token (for `supabase login`).

## 2. Apply the schema

```bash
cd ~/Work/peak
supabase login                      # paste the access token from 1.4
supabase link --project-ref <ref>   # it will ask for the DB password from 1.1
supabase db push                    # applies all 42 migrations to the cloud DB
```

`db push` runs every migration from scratch — the same set CI verifies on every
commit, so it should apply clean. If it stops, paste the error here.

## 3. Deploy the edge functions

```bash
supabase functions deploy app-version     # verify_jwt=false is read from config.toml
supabase functions deploy export
supabase functions deploy publish
supabase functions deploy ingest-content   # verify_jwt=false; space-feed mirror
```

No `supabase secrets set` needed — `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
`SUPABASE_SERVICE_ROLE_KEY` are injected into the edge runtime automatically.

## 4. Schedule the retention jobs

Dashboard → **SQL Editor**, run once:

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;   -- lets cron call the ingest Edge Function
select cron.schedule('purge-deletions', '17 4 * * *', $$select purge_expired_deletions()$$);
select cron.schedule('purge-accounts',  '33 4 * * *', $$select purge_due_accounts()$$);
select cron.schedule('purge-stories',   '7 * * * *',  $$select purge_expired_stories()$$);

-- space-feed mirror: @webb / @hubble / @roman / @launches, every 6h
select cron.schedule('ingest-content', '25 */6 * * *', $$
  select net.http_post(
    url     := 'https://<ref>.supabase.co/functions/v1/ingest-content',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer <anon-key>'),
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
$$);
```

## 5. Auth settings

Dashboard → **Authentication → URL Configuration**:

- **Site URL**: `https://shadow-1.tail51f9d6.ts.net:8720` (the Tailscale preview)
- **Redirect URLs**: add the same, plus `http://localhost:*` for local dev.

Email: the built-in Supabase sender (rate-limited, "from" is supabase.io) is fine
for a handful of testers. Real email (Resend + SPF/DKIM/DMARC) comes with the
domain — [DEPLOY.md](DEPLOY.md) §4. Keep **confirmations on**.

Storage buckets (`post-media`, `avatars`, `story-media`, `message-media`,
`exports`) are all created by migrations in step 2 — just confirm they're listed
under **Storage**.

## 6. Point the apps at it

```bash
cd ~/Work/peak/app
# web (redeploy to the Tailscale preview)
flutter build web --release \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key>
rsync -a --delete build/web/ ~/peak-web/ && systemctl --user restart peak-web

# a fresh signed APK against the hosted backend
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key>
```

The dev data on the Tailscale Supabase does **not** carry over — the hosted DB
starts empty. Run `tool/seed-directory.sql` against it (Supabase SQL editor, or
`psql` with the service role) to create the house `@peak` account, the
`@webb` / `@hubble` / `@roman` / `@launches` / `@playstation` / `@xbox` /
`@nintendo` / `@pcgaming` / `@pchardware` / `@scinews` mirror & news accounts,
and the starter communities (`c/space` `c/rockets` `c/gaming` `c/playstation`
`c/xbox` `c/nintendo` `c/pc-gaming` `c/pc-hardware` `c/science` `c/science-news`
`c/astrophotos`). It's idempotent and auto-follows/joins the oldest real
(non-`@peak.social`) account into everything + seeds its interests. Then trigger
the first content pull:
`curl -XPOST "$SUPABASE_URL/functions/v1/ingest-content?force=1" -H "Authorization: Bearer $ANON_KEY"`.

## 7. Wire the release pipeline (this is what publishes the APK)

`.github/workflows/release.yml` builds a signed APK on a `v*` tag and updates the
in-app updater manifest. It needs three repo settings:

| Kind | Name | Value |
|---|---|---|
| **Variable** | `RELEASE_SUPABASE_URL` | `https://<ref>.supabase.co` |
| **Secret** | `RELEASE_SUPABASE_ANON_KEY` | the `anon` key |
| **Secret** | `SUPABASE_SERVICE_ROLE_KEY` | the `service_role` key (manifest PATCH) |

```bash
gh variable set RELEASE_SUPABASE_URL   --body "https://<ref>.supabase.co"
gh secret   set RELEASE_SUPABASE_ANON_KEY   --body "<anon-key>"
gh secret   set SUPABASE_SERVICE_ROLE_KEY   --body "<service-role-key>"
```

(The Android signing secrets — `ANDROID_KEYSTORE_BASE64` etc. — are already set.)

Then cut a release. `app/pubspec.yaml` is already `1.0.0+1`, and the workflow
checks the tag matches, so:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

(For later releases: bump `version:` in `app/pubspec.yaml` — e.g. `1.0.1+2` —
commit, then tag `v1.0.1`.)

CI builds the signed APK, attaches it (+ `.sha256`) to a GitHub Release, and
PATCHes the `app_release` row so the in-app updater sees it.

---

## Checklist

- [ ] 1. Project created; ref / URL / anon / service_role saved; CLI token made
- [ ] 2. `supabase link` + `supabase db push` clean
- [ ] 3. `app-version`, `export`, `publish`, `ingest-content` deployed
- [ ] 4. `pg_cron` + `pg_net` enabled; 3 retention jobs + `ingest-content` scheduled; `tool/seed-directory.sql` run
- [ ] 5. Auth Site URL + redirect URLs set
- [ ] 6. Web rebuilt against the hosted URL + redeployed; fresh APK built
- [ ] 7. `RELEASE_SUPABASE_URL` / `RELEASE_SUPABASE_ANON_KEY` /
        `SUPABASE_SERVICE_ROLE_KEY` set; `v0.1.0` tagged → APK on Releases
- [ ] Later: domain → [DEPLOY.md](DEPLOY.md) §0–2, §4, §5
