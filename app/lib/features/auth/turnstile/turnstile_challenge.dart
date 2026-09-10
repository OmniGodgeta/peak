import 'package:flutter/widgets.dart';

import 'turnstile_stub.dart'
    if (dart.library.js_interop) 'turnstile_web.dart'
    as impl;

/// The Cloudflare Turnstile challenge. **Web only** — on other platforms this
/// renders nothing and [onToken] is never called (mobile sign-up during the
/// private beta doesn't gate on it). The Turnstile script is loaded lazily, and
/// only when this widget mounts, so it never touches users who don't sign up.
class TurnstileChallenge extends StatelessWidget {
  const TurnstileChallenge({
    super.key,
    required this.siteKey,
    required this.onToken,
  });

  final String siteKey;
  final void Function(String? token) onToken;

  @override
  Widget build(BuildContext context) =>
      impl.turnstileView(siteKey: siteKey, onToken: onToken);
}
