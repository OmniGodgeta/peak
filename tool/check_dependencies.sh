#!/usr/bin/env bash
# Fails if a known analytics / advertising / tracking SDK appears in the app's
# resolved dependency tree. Peak ships none — see docs/PRODUCT.md §9.1.
set -euo pipefail

LOCK="app/pubspec.lock"
[ -f "$LOCK" ] || { echo "no $LOCK — run 'flutter pub get' first"; exit 1; }

# Package-name fragments that must never appear as dependencies.
DENY=(
  firebase_analytics google_analytics gtag amplitude mixpanel segment
  appsflyer adjust_sdk facebook_ apps flyer branch_sdk
  google_mobile_ads unity_ads applovin ironsource admob
  sentry_flutter  # allowed later ONLY if self-hosted + PII-scrubbed; blocked for now
  posthog datadog_flutter newrelic
  onesignal singular_flutter kochava
)

fail=0
for frag in "${DENY[@]}"; do
  if grep -Eiq "^  ${frag}[a-z0-9_]*:" "$LOCK"; then
    echo "DENIED dependency matching '${frag}' found in $LOCK"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "Peak does not ship analytics/ad/tracking SDKs. If you believe an"
  echo "exception is warranted, raise it in an issue first — this check is policy."
  exit 1
fi

echo "dependency denylist: clean"
