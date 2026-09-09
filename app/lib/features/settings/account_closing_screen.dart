import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/data_repository.dart';
import '../../data/profile_repository.dart';
import '../../data/supabase_providers.dart';

/// Shown for the whole 30-day grace window after someone asks to delete their
/// account. The only ways forward are to keep the account or to sign out.
class AccountClosingScreen extends ConsumerStatefulWidget {
  const AccountClosingScreen({super.key});

  @override
  ConsumerState<AccountClosingScreen> createState() =>
      _AccountClosingScreenState();
}

class _AccountClosingScreenState extends ConsumerState<AccountClosingScreen> {
  bool _busy = false;

  Future<void> _keep() async {
    setState(() => _busy = true);
    try {
      await ref.read(dataRepositoryProvider).cancelAccountDeletion();
      ref.invalidate(myProfileProvider);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = ref.watch(myProfileProvider).asData?.value;
    final purgeAt = profile?.deletionPurgeAt;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.hourglass_top,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Your account is closing',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    purgeAt == null
                        ? 'It will be permanently deleted after the 30-day grace period.'
                        : 'Everything is permanently deleted on '
                              '${_date(purgeAt)}. Until then you can still change '
                              'your mind — your profile is hidden and you can’t '
                              'post in the meantime.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _busy ? null : _keep,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Keep my account'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => ref.read(supabaseProvider).auth.signOut(),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _date(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
