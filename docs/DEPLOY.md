# Going live

How Peak gets from `localhost` to a real, public URL. This is the **public-internet
layer** — domain, TLS, frontend hosting, email, and the go-live checklist. It sits on
top of whichever backend you run:

- **Hosted Supabase** — fastest path, covered here.
- **Self-hosted Supabase stack** — see [SELF_HOSTING.md](SELF_HOSTING.md) for the stack
  bring-up; come back here for the public ingress + checklist.

> Status: **not launched.** This is the plan; check items off as they ship.

Once the app is feature-complete, the technical deploy is **config, not engineering** —
roughly half a day to two days. The longer pole is the legal / moderation groundwork.

---

## 0. Decide the domain first — it is load-bearing

Handles are `@name@peak.social`. **The domain is baked into every user's identity.**
Changing `localhost` → `peak.social` now is trivial. Changing the domain *after* people
sign up means migrating every handle and breaking federation. Pick the final domain
before the first real user.

- [ ] Register **`peak.social`** (`.social` ≈ $25–35/yr — Porkbun or Cloudflare Registrar)
- [ ] Add it to Cloudflare (free plan) for DNS, CDN, DDoS, and Turnstile

---

## 1. Domain & DNS

| Record | Host | Points to | Purpose |
|---|---|---|---|
| `CNAME` / `A` | `peak.social`, `www` | frontend host | the web app |
| `CNAME` / `A` | `api.peak.social` | backend (or Supabase project) | REST / auth / realtime |
| `TXT` | `peak.social` | `v=spf1 include:...` | email SPF |
| `TXT` | `resend._domainkey` (etc.) | provider value | email DKIM |
| `TXT` | `_dmarc.peak.social` | `v=DMARC1; p=quarantine; rua=...` | email DMARC |

TLS is automatic on Cloudflare Pages / Supabase / Caddy. Never expose Supabase Studio
publicly — LAN / Tailscale only.

---

## 2. Frontend — Flutter Web

Flutter Web builds to static files:

```bash
cd app
flutter build web --release \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon-key>
```

- [ ] Deploy `app/build/web/` to **Cloudflare Pages** (free; CDN + DDoS included).
      Alternatives: Netlify, Firebase Hosting, or the `shadow` box behind Caddy.
- [ ] Connect the custom domain `peak.social`
- [ ] Wire the CI workflow (`.github/workflows/ci.yml`) to build + deploy on push to `main`
- [ ] Confirm PWA install works (manifest, service worker, icons)

**Do not commit real keys.** The anon key is safe to ship in the client (RLS is the
real boundary), but inject it at build time via `--dart-define` or CI secrets, not a
checked-in `env.json`.

---

## 3. Backend go-live

### Path A — Hosted Supabase (recommended to start)

```bash
supabase link --project-ref <new-project-ref>
supabase db push                 # applies every migration to the cloud DB
supabase functions deploy publish
supabase secrets set KEY=value   # any function secrets
```

- [ ] Create the project — **pick the region closest to users** (permanent)
- [ ] `supabase db push` — verify all migrations apply clean from scratch
- [ ] Deploy edge functions: `app-version`, `publish`, `export` (+ `push` later).
      `export` needs `SUPABASE_SERVICE_ROLE_KEY` in env — the edge runtime
      provides it by default; only a flag if a deploy overrides secrets.
- [ ] Confirm **storage buckets** exist after `db push` — all created by
      migrations, carry over automatically; just verify + re-check RLS:
      `post-media` (public), `avatars` (public), `story-media` (public),
      `message-media` (private), `exports` (private)
- [ ] **pg_cron** — enable the extension, then schedule the retention jobs
      (they're `SECURITY DEFINER` no-args, left out of migrations since
      scheduling is instance-specific and pg_cron isn't in the local stack):
      ```sql
      select cron.schedule('purge-deletions', '17 4 * * *', 'select purge_expired_deletions()');
      select cron.schedule('purge-accounts',  '33 4 * * *', 'select purge_due_accounts()');
      select cron.schedule('purge-stories',   '7 * * * *',  'select purge_expired_stories()');
      ```
- [ ] Skip or trim `seed.sql` for production
- [ ] Free tier launches fine; move to **Pro ($25/mo)** for daily backups, no
      auto-pause, and real resource limits before real traffic

### Path B — Self-hosted on `shadow`

Follow [SELF_HOSTING.md](SELF_HOSTING.md) for the stack, then for public reach:

- [ ] Public ingress: a VPS reverse-proxy or **Cloudflare Tunnel** in front of `shadow`
      (Tailscale Funnel is fine for a private beta, not for production bandwidth /
      uptime)
- [ ] Caddy / nginx terminating TLS for `peak.social` + `api.peak.social`
- [ ] Nightly `pg_dump` to off-box storage + test a restore
- [ ] `fail2ban` / rate limiting at the proxy

---

## 4. Email — required, easy to forget

Local signup mail goes to **Mailpit** (a fake inbox). Production needs a real sender or
nobody can confirm signup or reset a password.

- [ ] Pick a provider — **Resend** (3k/mo free) or AWS SES (cheap at scale)
- [ ] Wire SMTP into Supabase Auth (`[auth.email.smtp]` / dashboard)
- [ ] Add **SPF + DKIM + DMARC** DNS records — without them, confirmation mail is spam
- [ ] Set `enable_confirmations = true`
- [ ] Customise the auth email templates (from-name, branding, links to `peak.social`)
- [ ] Send a test signup to a Gmail + an Outlook address; confirm inbox placement

---

## 5. Config swap (local → prod)

The only code-level change is **three values**:

| Value | Local | Production |
|---|---|---|
| Supabase URL | `http://127.0.0.1:54321` | `https://<ref>.supabase.co` |
| anon key | local demo key | cloud project anon key |
| Auth **Site URL** + redirect URLs | `http://127.0.0.1:3000` | `https://peak.social` |

Everything else is dashboard / DNS config.

- [ ] Rotate off every local demo secret (`JWT_SECRET`, service_role key — never reuse)
- [ ] Set Auth **Site URL** and **additional redirect URLs** to the production domain
- [ ] Configure any OAuth providers (Google / Apple) with production redirect URLs

---

## 6. Pre-launch checklist — the real work

A public social network with **13+ and teen accounts** carries obligations from user #1.

### Legal / policy
- [ ] Terms of Service
- [ ] Privacy Policy (what's collected, retention, export, deletion — matches the VISION claims)
- [ ] Community Guidelines
- [ ] DMCA / copyright agent + contact
- [ ] Cookie / tracking notice (minimal, since no ads)

### Safety & moderation
- [ ] In-app **report / block / abuse** flow wired to something a human sees
- [ ] **NCMEC / CSAM reporting** path — legally mandatory for any service hosting uploads (US)
- [ ] A named person on call for moderation + a takedown SLA
- [ ] Minors: review UK Age Appropriate Design Code, EU DSA, US state age-verification
      laws before real teenagers are on it
- [ ] EU DSA: notice-and-action mechanism + point of contact if EU users

### Security & abuse
- [ ] `supabase db lint` clean; all `supabase test db` green against the prod schema
- [ ] Cloudflare **Turnstile** on signup; Supabase Auth rate limits tuned
- [ ] Review every RLS policy once more against the prod data
- [ ] Secrets in CI / host env only — nothing sensitive in the repo

### Ops
- [ ] Uptime monitor (UptimeRobot / Better Stack — free)
- [ ] Error tracking (Sentry) in app + edge functions
- [ ] Backups verified by an actual restore, not just "it's enabled"
- [ ] A rollback plan for a bad migration (`supabase db push` is forward-only)

---

## 7. Mobile apps (separate from the website)

Not needed for a web/PWA launch, but when ready:

- [ ] Google Play: $25 one-time; signed AAB; UGC + minors gets policy review
- [ ] Apple: $99/yr; App Store review is strict on social apps with UGC and minors
      (needs report/block, EULA, age rating)

---

## Cost

| | To launch | Running |
|---|---|---|
| Domain `.social` | ~$30 | ~$30/yr |
| Supabase | $0 | $0 → $25/mo |
| Frontend (Cloudflare Pages) | $0 | $0 |
| Email (Resend) | $0 | $0 → ~$20/mo |
| Cloudflare | $0 | $0 |
| **Total** | **~$30** | **~$25–70/mo** |

Self-hosting on `shadow` trades the Supabase fee for your time and the box's uptime.
