import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/profile_repository.dart';

class HarassmentShieldScreen extends ConsumerWidget {
  const HarassmentShieldScreen({super.key});

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    await action();
    ref.invalidate(myProfileProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Shield updated')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(myProfileProvider);
    final repo = ref.read(profileRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Harassment shield')),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('$err')),
        data: (profile) {
          if (profile == null) {
            return const Center(child: Text('No profile found.'));
          }
          final expiry = profile.harassmentShieldExpiresAt;
          final isOn = expiry != null;
          final isPermanent =
              isOn &&
              expiry.isAfter(
                DateTime.now().add(const Duration(days: 365 * 99)),
              );

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'While on, only you can see your posts. Everyone else '
                'sees nothing from you until it ends.',
              ),
              const SizedBox(height: 24),
              if (isOn) ...[
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.shield),
                    title: const Text('Shield is active'),
                    subtitle: Text(
                      isPermanent
                          ? 'Until you turn it off'
                          : 'Until ${_formatDate(expiry)}',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () =>
                      _apply(context, ref, repo.clearHarassmentShield),
                  icon: const Icon(Icons.close),
                  label: const Text('Turn off shield'),
                ),
              ] else ...[
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('1 hour'),
                  onTap: () => _apply(
                    context,
                    ref,
                    () => repo.setHarassmentShield(
                      duration: const Duration(hours: 1),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_today_outlined),
                  title: const Text('1 day'),
                  onTap: () => _apply(
                    context,
                    ref,
                    () => repo.setHarassmentShield(
                      duration: const Duration(days: 1),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_month_outlined),
                  title: const Text('1 week'),
                  onTap: () => _apply(
                    context,
                    ref,
                    () => repo.setHarassmentShield(
                      duration: const Duration(days: 7),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('Until I turn it off'),
                  onTap: () =>
                      _apply(context, ref, () => repo.setHarassmentShield()),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
