import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/personhood_repository.dart';
import '../../data/report_repository.dart';
import '../profile/user_profile_screen.dart';

/// Proof-of-personhood: the people you've vouched for, and — for staff — the
/// accounts partway to the vouch threshold.
class PersonhoodScreen extends ConsumerWidget {
  const PersonhoodScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vouches = ref.watch(myVouchesProvider);
    final isStaff = ref.watch(amIStaffProvider).asData?.value ?? false;
    final pending = isStaff ? ref.watch(personhoodPendingProvider) : null;

    void openProfile(String handle) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UserProfileScreen(handle: handle),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Proof of personhood')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'A “verified person” badge means real people stand behind an '
              'account — three vouches from already-verified people, or an '
              'operator confirmation. It is not identity verification.',
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('People you vouch for'),
          ),
          vouches.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) =>
                Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
            data: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'You haven’t vouched for anyone. Open a profile to vouch.',
                    ),
                  )
                : Column(
                    children: [
                      for (final v in list)
                        ListTile(
                          leading: Icon(
                            v.verified
                                ? Icons.verified
                                : Icons.hourglass_bottom,
                            color: v.verified
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          title: Text(
                            v.displayName.isEmpty ? v.handle : v.displayName,
                          ),
                          subtitle: Text('@${v.handle}'),
                          onTap: () => openProfile(v.handle),
                        ),
                    ],
                  ),
          ),
          if (pending != null) ...[
            const Divider(height: 24),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Close to the threshold (staff)'),
            ),
            pending.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) =>
                  Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
              data: (list) => list.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text('Nobody has vouches pending.'),
                    )
                  : Column(
                      children: [
                        for (final p in list)
                          ListTile(
                            title: Text(
                              p.displayName.isEmpty ? p.handle : p.displayName,
                            ),
                            subtitle: Text(
                              '@${p.handle} · ${p.vouchCount} vouches',
                            ),
                            trailing: TextButton(
                              onPressed: () async {
                                await ref
                                    .read(personhoodRepositoryProvider)
                                    .grant(p.handle);
                                ref
                                    .read(personhoodRevisionProvider.notifier)
                                    .bump();
                              },
                              child: const Text('Verify'),
                            ),
                            onTap: () => openProfile(p.handle),
                          ),
                      ],
                    ),
            ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
