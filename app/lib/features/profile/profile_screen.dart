import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/profile_repository.dart';
import '../../data/supabase_providers.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Me'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => ref.read(supabaseProvider).auth.signOut(),
          ),
        ],
      ),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (p) {
          if (p == null) return const Center(child: Text('No profile.'));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              CircleAvatar(
                radius: 36,
                child: Text(
                  (p.displayName.isNotEmpty ? p.displayName : p.handle)
                      .characters
                      .first
                      .toUpperCase(),
                  style: const TextStyle(fontSize: 28),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                p.displayName.isNotEmpty ? p.displayName : p.handle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(p.fqHandle, style: Theme.of(context).textTheme.bodyMedium),
              if (p.bio.isNotEmpty) ...[const SizedBox(height: 8), Text(p.bio)],
              const SizedBox(height: 8),
              if (p.accountKind == 'teen')
                const Chip(label: Text('Teen account — private by default')),
              const Divider(height: 32),
              const _ComingSoonTile(
                label: 'Edit profile, avatar, links',
                phase: 'Phase 0',
              ),
              const _ComingSoonTile(
                label: 'Circles & who is in them',
                phase: 'Phase 1',
              ),
              const _ComingSoonTile(label: 'Your posts', phase: 'Phase 1'),
              const _ComingSoonTile(
                label: 'Data export & real delete',
                phase: 'Phase 3',
              ),
              const _ComingSoonTile(
                label: 'Wellbeing & screen-time',
                phase: 'Phase 5',
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ComingSoonTile extends StatelessWidget {
  const _ComingSoonTile({required this.label, required this.phase});
  final String label;
  final String phase;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: Text(phase, style: Theme.of(context).textTheme.labelSmall),
      dense: true,
      enabled: false,
    );
  }
}
