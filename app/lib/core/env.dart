/// Compile-time configuration.
///
/// Supply with `--dart-define-from-file=env.json` (see `env.example.json`).
library;

class Env {
  const Env._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Deep-link / OAuth redirect target. Overridden per platform build.
  static const authRedirect = String.fromEnvironment(
    'AUTH_REDIRECT',
    defaultValue: 'peak://auth-callback',
  );

  /// Base URL (ending in `/v1`) of the self-hosted Peak media server that holds
  /// post images + video. When empty, media falls back to Supabase Storage.
  /// See tool/media-server/.
  static const mediaBaseUrl = String.fromEnvironment('PEAK_MEDIA_URL');

  static bool get mediaServerConfigured => mediaBaseUrl.isNotEmpty;

  /// Cloudflare Turnstile site key. When set, sign-up requires a Turnstile
  /// challenge and passes the token to Supabase Auth (which must also have
  /// CAPTCHA enabled in the dashboard). Empty = no challenge. Needs a
  /// registered domain to issue a real key — see docs/DEPLOY.md.
  static const turnstileSiteKey = String.fromEnvironment('TURNSTILE_SITE_KEY');

  /// OAuth providers switched on for this build, comma-separated, e.g.
  /// `github,google,discord`. Each must also be enabled (client id + secret)
  /// in the Supabase dashboard — see docs/HOSTED_BACKEND.md §5a. Empty = no
  /// OAuth buttons, email only.
  static const oauthProviders = String.fromEnvironment('OAUTH_PROVIDERS');

  /// Calls: STUN server, and an optional TURN relay (url + credentials) for
  /// peers behind strict NAT. Without TURN some calls can't connect.
  static const stunUrl = String.fromEnvironment(
    'STUN_URL',
    defaultValue: 'stun:stun.l.google.com:19302',
  );
  static const turnUrl = String.fromEnvironment('TURN_URL');
  static const turnUsername = String.fromEnvironment('TURN_USERNAME');
  static const turnCredential = String.fromEnvironment('TURN_CREDENTIAL');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
