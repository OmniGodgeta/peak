-- Peak — app release manifest for the in-app updater.
--
-- The sideloaded Android build (no Play Store yet) checks this to know when a
-- newer APK exists. One row per platform. Read is public (the updater runs
-- before sign-in and for signed-out users); writes are service-role only
-- (CI updates the row on a tagged release), so there is no write policy.

create table app_release (
  platform                   text primary key
                             check (platform in ('android', 'ios', 'web')),
  version_name               text not null,
  version_code               integer not null check (version_code > 0),
  apk_url                    text,
  sha256                     text check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  notes                      text,
  min_supported_version_code integer not null default 1 check (min_supported_version_code > 0),
  published_at               timestamptz not null default now()
);

alter table app_release enable row level security;

create policy "app_release is world-readable"
  on app_release for select
  using (true);

-- Seed the current Android build (pubspec: 1.0.0+1). CI overwrites this on a
-- tagged release; apk_url stays null until there is a public download.
insert into app_release (platform, version_name, version_code, min_supported_version_code, notes)
values ('android', '1.0.0', 1, 1, 'Initial internal build.');
