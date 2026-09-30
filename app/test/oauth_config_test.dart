import 'package:flutter_test/flutter_test.dart';
import 'package:peak/features/auth/oauth_buttons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('parses the OAUTH_PROVIDERS list, ignoring junk and duplicates', () {
    expect(configuredOAuthProviders(''), isEmpty);
    expect(configuredOAuthProviders(' GitHub , google,nope,github'), [
      OAuthProvider.github,
      OAuthProvider.google,
    ]);
  });

  test('labels', () {
    expect(oauthLabel(OAuthProvider.github), 'GitHub');
    expect(oauthLabel(OAuthProvider.azure), 'Microsoft');
  });
}
