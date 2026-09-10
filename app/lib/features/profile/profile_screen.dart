import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/profile_repository.dart';
import '../../data/settings_repository.dart';
import '../../data/supabase_providers.dart';
import '../../updater/update_gate.dart';
import '../../updater/update_service.dart';
import '../../data/community_repository.dart';
import '../../data/report_repository.dart';
import '../communities/modmail/my_modmail_screen.dart';
import '../moderation/my_reports_screen.dart';
import '../moderation/review_queue_screen.dart';
import '../settings/devices_screen.dart';
import '../settings/wellbeing_screen.dart';
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
              ListTile(
                leading: const Icon(Icons.mail_outline),
                title: const Text('Moderator messages'),
                subtitle: const Text(
                  'Your private threads with community mods',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MyModmailScreen(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Your reports'),
                subtitle: const Text('What you reported and what happened'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MyReportsScreen(),
                  ),
                ),
              ),
              if (ref.watch(amIStaffProvider).asData?.value == true ||
                  (ref.watch(myCommunitiesProvider).asData?.value ?? const [])
                      .any((c) => c.myRole != 'member'))
                ListTile(
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Reports to review'),
                  subtitle: const Text('The moderation queue'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ReviewQueueScreen(),
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
              SwitchListTile(
                secondary: const Icon(Icons.data_saver_off_outlined),
                title: const Text('Data-light mode'),
                subtitle: const Text('Don’t load images until you tap them'),
                value: ref.watch(dataLightProvider),
                onChanged: (v) => ref.read(dataLightProvider.notifier).set(v),
              ),
              ListTile(
                leading: const Icon(Icons.self_improvement_outlined),
                title: const Text('Wellbeing'),
                subtitle: const Text(
                  'Take-a-break reminders, greyscale, quiet hours',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const WellbeingScreen(),
                  ),
                ),
              ),
              const Divider(height: 32),
              const _VersionTile(),
            ],
          );
        },
      ),
    );
  }
}

class _VersionTile extends ConsumerWidget {
  const _VersionTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionLabelProvider).asData?.value ?? '…';
    final check = ref.watch(updateCheckProvider);
    final status = check.asData?.value.status;

    final (String subtitle, VoidCallback onTap) = switch (status) {
      UpdateStatus.available => (
        'Update available — tap to install',
        () {
          final r = check.asData?.value.release;
          if (r != null) showUpdateSheet(context, r);
        },
      ),
      _ => (
        check.isLoading ? 'Checking…' : "You're up to date",
        () => ref.invalidate(updateCheckProvider),
      ),
    };

    return ListTile(
      leading: const Icon(Icons.system_update_outlined),
      title: Text('Peak $version'),
      subtitle: Text(subtitle),
      trailing: status == UpdateStatus.available
          ? Icon(
              Icons.circle,
              size: 10,
              color: Theme.of(context).colorScheme.primary,
            )
          : const Icon(Icons.refresh, size: 18),
      onTap: onTap,
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
