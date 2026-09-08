import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/profile_repository.dart';
import '../../data/supabase_providers.dart';

/// First run after sign-up: pick a handle + display name, create the account
/// (profile + default persona + five system circles via `bootstrap_account`).
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _handle = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  static final _handleRe = RegExp(r'^[a-z0-9_]{2,30}$');

  @override
  void dispose() {
    _handle.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final handle = _handle.text.trim().toLowerCase();
    if (!_handleRe.hasMatch(handle)) {
      setState(() => _error = 'Handle: 2–30 chars, a–z, 0–9, underscore.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(profileRepositoryProvider);
      if (!await repo.handleAvailable(handle)) {
        setState(() => _error = '@$handle is taken.');
        return;
      }
      await repo.bootstrap(handle: handle, displayName: _name.text.trim());
      ref.invalidate(myProfileProvider);
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your account'),
        actions: [
          TextButton(
            onPressed: () => ref.read(supabaseProvider).auth.signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _handle,
                  decoration: const InputDecoration(
                    labelText: 'Handle',
                    prefixText: '@',
                    helperText: 'Lowercase letters, numbers, underscore.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Display name (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _finish,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create account'),
                ),
                const SizedBox(height: 12),
                Text(
                  'You start with five circles — Public, Friends, Close Friends, '
                  'Family, Work. Every post you make is addressed to one of them.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
