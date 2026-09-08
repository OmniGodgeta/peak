import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/profile_repository.dart';
import '../../data/supabase_providers.dart';

/// First run after sign-up: pick a handle + display name, give a date of birth
/// (13+ enforced server-side; under-18 becomes a teen account), then create the
/// account — profile + private row + default persona + five system circles.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _handle = TextEditingController();
  final _name = TextEditingController();
  DateTime? _birthdate;
  bool _busy = false;
  String? _error;

  static final _handleRe = RegExp(r'^[a-z0-9_]{2,30}$');
  static const _domain = 'peak.social';

  @override
  void dispose() {
    _handle.dispose();
    _name.dispose();
    super.dispose();
  }

  int _ageOn(DateTime d) {
    final now = DateTime.now();
    var age = now.year - d.year;
    if (now.month < d.month || (now.month == d.month && now.day < d.day)) age--;
    return age;
  }

  Future<void> _pickBirthdate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(now.year - 120),
      lastDate: now,
      helpText: 'Your date of birth',
    );
    if (picked != null) setState(() => _birthdate = picked);
  }

  Future<void> _finish() async {
    final handle = _handle.text.trim().toLowerCase();
    if (!_handleRe.hasMatch(handle)) {
      setState(() => _error = 'Handle: 2–30 chars, a–z, 0–9, underscore.');
      return;
    }
    if (_birthdate == null) {
      setState(() => _error = 'Please enter your date of birth.');
      return;
    }
    if (_ageOn(_birthdate!) < 13) {
      setState(() => _error = 'You must be at least 13 to use Peak.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(profileRepositoryProvider);
      if (!await repo.handleAvailable(handle)) {
        setState(() => _error = '@$handle@$_domain is taken.');
        return;
      }
      await repo.bootstrap(
        handle: handle,
        displayName: _name.text.trim(),
        birthdate: _birthdate!,
      );
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
    final willBeTeen = _birthdate != null && _ageOn(_birthdate!) < 18;

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
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Handle',
                    prefixText: '@',
                    suffixText: '@$_domain',
                    helperText: 'Lowercase letters, numbers, underscore.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Display name (optional)',
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _pickBirthdate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date of birth',
                      helperText:
                          'Used to check you’re 13+. Never shown to anyone.',
                    ),
                    child: Text(
                      _birthdate == null
                          ? 'Tap to choose'
                          : ProfileRepository.isoDate(_birthdate!),
                    ),
                  ),
                ),
                if (willBeTeen) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 18,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Under 18 — your account will be private by default, '
                          'with no DMs from people you don’t know and no '
                          'manipulative retention features.',
                        ),
                      ),
                    ],
                  ),
                ],
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
