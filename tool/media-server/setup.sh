#!/usr/bin/env bash
# One-time setup for the Peak media server (runs on the machine that will hold
# the files — "shadow"). Idempotent.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cfg="$HOME/.config/peak-media"
unit="$HOME/.config/systemd/user/peak-media.service"

echo "== checking tools"
for bin in deno ffmpeg ffprobe; do
  command -v "$bin" >/dev/null || { echo "MISSING: $bin (install it, e.g. sudo pacman -S $bin)"; exit 1; }
done
echo "ok: $(deno --version | head -1), $(ffmpeg -version | head -1)"

mkdir -p "$cfg" "$(dirname "$unit")"

if [ ! -f "$cfg/env" ]; then
  cp "$here/env.example" "$cfg/env"
  echo
  echo ">> Wrote $cfg/env from the template. EDIT IT:"
  echo "   - MEDIA_ROOT   : a folder on a drive with room (default is your Game SSD)"
  echo "   - PUBLIC_BASE  : the https URL tailscale will expose, ending in /v1"
  echo "   - SUPABASE_URL / SUPABASE_ANON_KEY : the hosted project (anon key is public/safe)"
  echo "   Then re-run this script."
  exit 0
fi

# shellcheck disable=SC1090
set -a; source "$cfg/env"; set +a
: "${MEDIA_ROOT:?set MEDIA_ROOT in $cfg/env}"
: "${PUBLIC_BASE:?set PUBLIC_BASE in $cfg/env}"

echo "== media root: $MEDIA_ROOT"
if ! mkdir -p "$MEDIA_ROOT" 2>/dev/null; then
  echo "!! could not create $MEDIA_ROOT — is the drive mounted?"
  exit 1
fi
echo "ok, writable"

cp "$here/peak-media.service" "$unit"
systemctl --user daemon-reload
systemctl --user enable --now peak-media.service
sleep 1
systemctl --user --no-pager status peak-media.service | head -8 || true

port="${PORT:-8787}"
echo
echo "== local health:"
curl -fsS "http://127.0.0.1:$port/v1/health" && echo || echo "(not healthy yet — check: journalctl --user -u peak-media -e)"

# Derive the port tailscale should expose from PUBLIC_BASE (…:PORT/v1)
ext_port="$(printf '%s' "$PUBLIC_BASE" | sed -n 's#.*:\([0-9]\+\)/v1$#\1#p')"
ext_port="${ext_port:-8790}"
echo
echo "== LAST STEP — expose it on your tailnet (run this yourself; tailscale funnel/serve is blocked in Claude's session):"
echo
echo "   tailscale serve --bg --https $ext_port http://127.0.0.1:$port"
echo
echo "Then build the app with:  --dart-define=PEAK_MEDIA_URL=$PUBLIC_BASE"
echo "(add PEAK_MEDIA_URL to app/env.json and the web build env)"
