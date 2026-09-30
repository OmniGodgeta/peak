import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/env.dart';
import '../../data/supabase_providers.dart';

/// Providers this build offers, in the order given in `OAUTH_PROVIDERS`.
/// Unknown names are ignored rather than crashing the sign-in screen.
List<OAuthProvider> configuredOAuthProviders([String raw = Env.oauthProviders]) {
  final byName = {for (final p in OAuthProvider.values) p.name.toLowerCase(): p};
  final out = <OAuthProvider>[];
  for (final part in raw.split(',')) {
    final p = byName[part.trim().toLowerCase()];
    if (p != null && !out.contains(p)) out.add(p);
  }
  return out;
}

String oauthLabel(OAuthProvider p) => switch (p) {
  OAuthProvider.github => 'GitHub',
  OAuthProvider.gitlab => 'GitLab',
  OAuthProvider.google => 'Google',
  OAuthProvider.apple => 'Apple',
  OAuthProvider.discord => 'Discord',
  OAuthProvider.twitch => 'Twitch',
  OAuthProvider.azure => 'Microsoft',
  OAuthProvider.linkedinOidc => 'LinkedIn',
  OAuthProvider.slackOidc => 'Slack',
  OAuthProvider.spotify => 'Spotify',
  _ => p.name[0].toUpperCase() + p.name.substring(1),
};

/// Where the provider sends the browser back to: this page on web, the
/// peak://auth-callback deep link on phones.
String? oauthRedirect() => kIsWeb ? Uri.base.origin : Env.authRedirect;

/// "Continue with …" buttons for each configured provider. Signs in, or
/// creates the account; a new account then goes through onboarding (handle
/// + date of birth) like an email sign-up, via the router's no-profile
/// redirect.
class OAuthButtons extends ConsumerStatefulWidget {
  const OAuthButtons({super.key, this.enabled = true});
  final bool enabled;

  @override
  ConsumerState<OAuthButtons> createState() => _OAuthButtonsState();
}

class _OAuthButtonsState extends ConsumerState<OAuthButtons> {
  OAuthProvider? _pending;
  String? _error;

  Future<void> _go(OAuthProvider p) async {
    setState(() {
      _pending = p;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).auth.signInWithOAuth(
        p,
        redirectTo: oauthRedirect(),
        authScreenLaunchMode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = configuredOAuthProviders();
    if (providers.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('or', style: Theme.of(context).textTheme.bodySmall),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 8),
        for (final p in providers)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              onPressed: widget.enabled && _pending == null ? () => _go(p) : null,
              child: _pending == p
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('Continue with ${oauthLabel(p)}'),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}
