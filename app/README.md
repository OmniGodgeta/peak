# Peak app

Flutter client for iOS, Android, and Web. See the repo root
[`README.md`](../README.md), [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md),
and [`docs/CONTRIBUTING.md`](../docs/CONTRIBUTING.md).

## Run

```bash
# from repo root: start a local backend first
cd ../supabase && supabase start && supabase db reset && cd ../app

cp env.example.json env.json     # paste the URL + anon key from `supabase start`
flutter pub get
flutter run --dart-define-from-file=env.json          # device / emulator
flutter run -d chrome --dart-define-from-file=env.json # web
```

Built without the `--dart-define`s, the app still boots — to a screen explaining
what's missing.

## Layout

```
lib/
  app/        shell: bootstrap, router (go_router), theme
  core/       env + shared utilities
  data/       Supabase client wrapper, repositories, Riverpod providers
  features/
    auth/         sign-in, onboarding (handle + bootstrap_account RPC)
    home/         four-pillar NavigationBar shell + placeholders
    feed/         named feeds, "you're caught up", post tiles
    messaging/    (Phase 2)
    communities/  (Phase 4)
    discovery/    (Phase 5)
    profile/      me
    settings/     not-configured screen
```

## Checks (run before pushing)

```bash
dart format .
flutter analyze --fatal-infos
flutter test
```
