# 2026-10-03 — app_release now advertises v1.4.0

The hosted `app_release` row was still 1.0.5 (version code 6). The v1.4.0
release workflow skipped the update because `SUPABASE_SERVICE_ROLE_KEY`
was not a GitHub secret.

Updated the linked project `izvcozvfqmggyziaeeoc` (the URL baked into the
GitHub APK):

- version_name 1.4.0, version_code 23
- apk `peak-1.4.0-release.apk`
- sha256 matches the `.sha256` file on the v1.4.0 release
- notes: End-to-end encrypted chats.
- min_supported_version_code left at 1, so older installs are offered the
  update and are not blocked

Verified with a live GET of `/functions/v1/app-version`: versionName 1.4.0,
versionCode 23.

The local Docker database row was updated to the same values. The
service-role key is now the `SUPABASE_SERVICE_ROLE_KEY` repo secret, so a
future tag runs the existing "Update app_release manifest" step.

The two-phone encrypted-chat check and the Auth site URL are still for
the operator. Ethereal Haven was not touched.
