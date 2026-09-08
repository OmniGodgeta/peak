# Contributing

Peak is built in the open. Contributions are welcome once Phase 0 lands; until then
the schema and app shell are moving fast.

## Ground rules

- Be decent. The [Code of Conduct](CODE_OF_CONDUCT.md) applies everywhere.
- By contributing you agree your work is licensed under **AGPL-3.0**.
- No analytics, ad, or tracking SDKs. Ever. CI enforces a dependency denylist.
- Accessibility is not optional: new UI ships with semantics labels and is checked with a
  screen reader.

## Setup

Prereqs: Flutter ≥ 3.47, Dart ≥ 3.8, Node ≥ 20, Docker, Supabase CLI.

```bash
git clone https://github.com/OmniGodgeta/peak
cd peak/supabase && supabase start && supabase db reset
cd ../app && cp .env.example .env   # paste the URL + anon key from `supabase start`
flutter pub get && flutter run
```

## Project layout

```
app/lib/
  app/            app shell: router, theme, bootstrap
  core/           shared utilities, error types, result
  data/           Supabase client wrapper, local store (Drift), models
  features/
    auth/         onboarding, sign-in
    feed/         feeds, ranking client, "why am I seeing this"
    compose/      post composer
    profile/
    messaging/
    communities/
    discovery/
    settings/
supabase/
  migrations/     timestamped SQL, forward-only
  functions/      Deno Edge Functions
  seed.sql        local dev seed data
  tests/          pgTAP / policy tests
```

## Workflow

1. Find or open an issue; comment to claim it.
2. Branch from `main`: `feat/<short-name>` or `fix/<short-name>`.
3. Keep PRs focused. A schema change and a feature that uses it can be one PR; two
   unrelated features are two PRs.
4. **Schema changes**: add a new forward-only migration in `supabase/migrations/`. Never
   edit an applied migration. Include RLS policies and policy tests in the same PR.
5. Run before pushing:
   ```bash
   cd app && dart format . && flutter analyze && flutter test
   cd ../supabase && supabase db lint && supabase test db
   ```
6. Open the PR against `main`. CI must be green. One maintainer review to merge.

## Commit style

Conventional-ish: `feat(feed): add friends-first ordering`, `fix(auth): …`,
`docs(...)`, `chore(...)`, `refactor(...)`, `test(...)`.

## Coding standards

- **Dart**: `dart format`; lints in `app/analysis_options.yaml` are errors, not warnings.
  Prefer `sealed` classes + pattern matching for state; Riverpod for DI; no singletons
  holding mutable state.
- **SQL**: snake_case; every table has RLS enabled and an explicit deny-by-default; every
  policy has a test; foreign keys always; timestamps `timestamptz default now()`.
- **Edge Functions**: TypeScript, Deno std only where possible; no secret in a log line;
  every function has a happy-path and an authz-failure test.
- **No secrets in the repo.** `.env` is gitignored; use `.env.example` for shape.

## Tests

- App: widget tests for every screen with logic; golden tests for key components; a small
  integration suite against local Supabase.
- DB: pgTAP for constraints and functions; policy tests that assert each RLS rule both
  allows the intended case and denies the unintended one.
- Ranking: a dedicated suite asserting excluded signals (dwell time, rage-click proxies)
  never enter the score.

## Security-sensitive areas

Changes to auth, RLS, crypto, payments, media handling, or federation get an extra review
and, where relevant, a threat-model note in the PR. See [SECURITY.md](SECURITY.md).
