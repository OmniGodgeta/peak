#!/usr/bin/env bash
# Bring the hosted project (izvcozvfqmggyziaeeoc) up to date with main, then
# optionally cut the release. Run from anywhere:
#
#   SUPABASE_ACCESS_TOKEN=sbp_... tool/push-hosted.sh
#
# The token must be a full (unscoped) personal access token — dashboard →
# Account → Access tokens. Scoped tokens fail CLI calls with confusing
# permission errors (see AGENTS.md, "hosted drift"). The DB password is
# prompted by `supabase link`.
#
# Order matters: migrations first, THEN the release tag. A release APK
# talks to the hosted database, so tagging before the push would ship an
# app calling functions that don't exist yet (the 2026-09-26 outage).
set -euo pipefail
: "${SUPABASE_ACCESS_TOKEN:?set SUPABASE_ACCESS_TOKEN (full-scope personal access token)}"
REF=izvcozvfqmggyziaeeoc
cd "$(dirname "$0")/.."

ask() { read -r -p "$1 [y/N] " a; [[ "$a" == [yY]* ]]; }

echo "==> Linking to $REF"
supabase link --project-ref "$REF"

echo "==> Migration status (local vs hosted)"
supabase migration list --linked

echo "==> What db push would apply"
supabase db push --dry-run

if ask "Apply these migrations to the hosted database?"; then
  supabase db push
else
  echo "Stopped before pushing. Nothing changed."; exit 1
fi

echo "==> Deploying edge functions that are new or changed since v1.2.0"
supabase functions deploy purge-media
supabase functions deploy push-dispatch
supabase functions deploy federation --no-verify-jwt
supabase functions deploy federation-deliver

cat <<'SQL'

==> Run once in the dashboard SQL editor (replace <anon-key>):

select cron.schedule('purge-media', '47 4 * * *', $$
  select net.http_post(
    url := 'https://izvcozvfqmggyziaeeoc.supabase.co/functions/v1/purge-media',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <anon-key>'),
    body := '{}'::jsonb);
$$);

select cron.schedule('push-dispatch', '* * * * *', $$
  select net.http_post(
    url := 'https://izvcozvfqmggyziaeeoc.supabase.co/functions/v1/push-dispatch',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <anon-key>'),
    body := '{}'::jsonb);
$$);

-- federation-deliver: only once federation is switched on (needs a domain;
-- docs/HOSTED_BACKEND.md §4b).

SQL

version=$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' app/pubspec.yaml)
if ask "Tag v$version and let CI build + publish the release?"; then
  git tag "v$version"
  git push origin "v$version"
  echo "Tagged v$version — .github/workflows/release.yml takes it from here."
fi
