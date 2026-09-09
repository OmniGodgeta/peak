#!/usr/bin/env bash
# Apply Peak's schema + functions to a hosted Supabase project and rebuild the
# clients against it. Run from the repo root after:
#
#   supabase login                     # once, with a CLI access token
#   export PEAK_SUPABASE_REF=abcdefghijklmnop
#   export PEAK_SUPABASE_URL=https://abcdefghijklmnop.supabase.co
#   export PEAK_SUPABASE_ANON_KEY=eyJ...
#
# See docs/HOSTED_BACKEND.md for the full runbook (pg_cron jobs + auth settings
# are dashboard steps this script does NOT do).
set -euo pipefail

: "${PEAK_SUPABASE_REF:?set PEAK_SUPABASE_REF}"
: "${PEAK_SUPABASE_URL:?set PEAK_SUPABASE_URL}"
: "${PEAK_SUPABASE_ANON_KEY:?set PEAK_SUPABASE_ANON_KEY}"

cd "$(dirname "$0")/.."

echo "==> Linking to $PEAK_SUPABASE_REF (will prompt for the DB password)"
supabase link --project-ref "$PEAK_SUPABASE_REF"

echo "==> Pushing migrations"
supabase db push

echo "==> Deploying edge functions"
supabase functions deploy app-version
supabase functions deploy export
supabase functions deploy publish

echo "==> Rebuilding the web app against the hosted backend"
( cd app && flutter build web --release \
    --dart-define=SUPABASE_URL="$PEAK_SUPABASE_URL" \
    --dart-define=SUPABASE_ANON_KEY="$PEAK_SUPABASE_ANON_KEY" )

if [ -d "$HOME/peak-web" ]; then
  rsync -a --delete app/build/web/ "$HOME/peak-web/"
  systemctl --user restart peak-web.service 2>/dev/null || true
  echo "==> Redeployed to the Tailscale preview"
fi

cat <<EOF

Done. Still manual (dashboard):
  - SQL Editor: create extension pg_cron; + the 3 cron.schedule() calls
  - Auth -> URL Configuration: Site URL + redirect URLs
  - gh variable/secret set for the release workflow (see HOSTED_BACKEND.md step 7)
EOF
