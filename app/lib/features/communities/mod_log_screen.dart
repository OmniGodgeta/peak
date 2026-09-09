import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/community_repository.dart';

/// The transparent moderation log — every mod action, visible to any member.
class ModLogScreen extends ConsumerWidget {
  const ModLogScreen({super.key, required this.communityId});
  final String communityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(communityModLogProvider(communityId));

    return Scaffold(
      appBar: AppBar(title: const Text('Moderation log')),
      body: log.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (entries) {
          if (entries.isEmpty) {
            return const Center(child: Text('No moderator actions yet.'));
          }
          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final e = entries[i];
              return ListTile(
                leading: Icon(_iconFor(e.action), size: 20),
                title: Text(e.describe()),
                subtitle: e.reason != null && e.reason!.isNotEmpty
                    ? Text('“${e.reason}” · ${_ago(e.createdAt)}')
                    : Text(_ago(e.createdAt)),
              );
            },
          );
        },
      ),
    );
  }

  static IconData _iconFor(String action) => switch (action) {
    'approve_request' => Icons.person_add_alt,
    'decline_request' => Icons.person_off_outlined,
    'set_role' => Icons.shield_outlined,
    'remove_member' || 'ban_member' => Icons.person_remove_outlined,
    'unban_member' => Icons.lock_open_outlined,
    'label_post' => Icons.label_outline,
    'unlabel_post' => Icons.label_off_outlined,
    'remove_post' => Icons.delete_outline,
    'edit_settings' => Icons.tune,
    _ => Icons.gavel_outlined,
  };
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}
