import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/supabase_providers.dart';
import '../auth/oauth_buttons.dart';

/// The ways this account can sign in: email + password, and any linked
/// OAuth identities. Linking needs "manual linking" on in Supabase Auth
/// (docs/HOSTED_BACKEND.md §5a); unlinking the last method is refused by
/// Supabase itself.
class SignInMethodsScreen extends ConsumerStatefulWidget {
  const SignInMethodsScreen({super.key});

  @override
  ConsumerState<SignInMethodsScreen> createState() =>
      _SignInMethodsScreenState();
}

class _SignInMethodsScreenState extends ConsumerState<SignInMethodsScreen> {
  List<UserIdentity>? _identities;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ids = await ref.read(supabaseProvider).auth.getUserIdentities();
      if (mounted) setState(() => _identities = ids);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _run(Future<void> Function(GoTrueClient auth) f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f(ref.read(supabaseProvider).auth);
      await _load();
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _label(String provider) {
    if (provider == 'email') return 'Email and password';
    for (final p in OAuthProvider.values) {
      if (p.name.toLowerCase() == provider.toLowerCase()) return oauthLabel(p);
    }
    return provider;
  }

  @override
  Widget build(BuildContext context) {
    final ids = _identities;
    final linked = {for (final i in ids ?? const <UserIdentity>[]) i.provider};
    final linkable = configuredOAuthProviders()
        .where((p) => !linked.contains(p.name.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Sign-in methods')),
      body: ids == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                for (final i in ids ?? const <UserIdentity>[])
                  ListTile(
                    leading: Icon(
                      i.provider == 'email'
                          ? Icons.mail_outline
                          : Icons.link_outlined,
                    ),
                    title: Text(_label(i.provider)),
                    subtitle: Text(
                      (i.identityData?['email'] as String?) ?? 'Linked',
                    ),
                    trailing: i.provider != 'email' && ids!.length > 1
                        ? TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run((a) => a.unlinkIdentity(i)),
                            child: const Text('Unlink'),
                          )
                        : null,
                  ),
                if (linkable.isNotEmpty) ...[
                  const Divider(),
                  for (final p in linkable)
                    ListTile(
                      leading: const Icon(Icons.add_link),
                      title: Text('Link ${oauthLabel(p)}'),
                      subtitle: const Text(
                        'Sign in with it next time, same account',
                      ),
                      onTap: _busy
                          ? null
                          : () => _run(
                              (a) => a.linkIdentity(
                                p,
                                redirectTo: oauthRedirect(),
                                authScreenLaunchMode: kIsWeb
                                    ? LaunchMode.platformDefault
                                    : LaunchMode.externalApplication,
                              ),
                            ),
                    ),
                ],
              ],
            ),
    );
  }
}
