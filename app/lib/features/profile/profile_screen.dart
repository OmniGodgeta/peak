import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/profile_repository.dart';
import '../../data/supabase_providers.dart';
import '../settings/devices_screen.dart';
import '../settings/your_data_screen.dart';
import 'edit_profile_screen.dart';
import 'user_profile_screen.dart';

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
          final repo = ref.read(profileRepositoryProvider);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              CircleAvatar(
                radius: 36,
                backgroundImage: p.avatarPath != null
                    ? NetworkImage(repo.avatarUrl(p.avatarPath!))
                    : null,
                child: p.avatarPath == null
                    ? Text(
                        p.displayNameOrHandle.characters.first.toUpperCase(),
                        style: const TextStyle(fontSize: 28),
                      )
                    : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.displayNameOrHandle,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          p.fqHandle,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        if (p.pronouns != null && p.pronouns!.isNotEmpty)
                          Text(
                            p.pronouns!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => EditProfileScreen(profile: p),
                      ),
                    ),
                    child: const Text('Edit'),
                  ),
                ],
              ),
              if (p.bio.isNotEmpty) ...[const SizedBox(height: 8), Text(p.bio)],
              if (p.locationCoarse != null && p.locationCoarse!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.place_outlined,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      p.locationCoarse!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
              if (p.links.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final l in p.links)
                      ActionChip(
                        avatar: const Icon(Icons.link, size: 14),
                        label: Text(l.label.isNotEmpty ? l.label : l.url),
                        onPressed: () {
                          final uri = Uri.tryParse(l.url);
                          if (uri != null) {
                            launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              if (p.isTeen)
                const Chip(label: Text('Teen account — private by default')),
              const Divider(height: 32),
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: const Text('Your profile & posts'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => UserProfileScreen(handle: p.handle),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.devices_outlined),
                title: const Text('Devices'),
                subtitle: const Text('Where your account is signed in'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DevicesScreen(),
                  ),
                ),
              ),
              const _ComingSoonTile(
                label: 'Circles & who is in them',
                phase: 'Phase 1',
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Your data'),
                subtitle: const Text('Export everything · recently deleted'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const YourDataScreen(),
                  ),
                ),
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
