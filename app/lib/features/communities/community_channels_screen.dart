import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/community_repository.dart';

/// Admin screen: add, edit, and remove a community's text channels.
class CommunityChannelsScreen extends ConsumerWidget {
  const CommunityChannelsScreen({super.key, required this.community});
  final Community community;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(communityChannelsProvider(community.id));

    void refresh() => ref.invalidate(communityChannelsProvider(community.id));

    return Scaffold(
      appBar: AppBar(title: const Text('Channels')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final made = await _editChannel(context, ref, community.id, null);
          if (made) refresh();
        },
        icon: const Icon(Icons.add),
        label: const Text('Add channel'),
      ),
      body: channels.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            for (final ch in list)
              ListTile(
                leading: Icon(
                  ch.modsOnly ? Icons.campaign_outlined : Icons.tag,
                ),
                title: Text('#${ch.name}'),
                subtitle: Text(
                  [
                    if (ch.description.isNotEmpty) ch.description,
                    '${ch.postCount} post${ch.postCount == 1 ? '' : 's'}',
                    if (ch.modsOnly) 'moderators only',
                  ].join(' · '),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      final ok = await _editChannel(
                        context,
                        ref,
                        community.id,
                        ch,
                      );
                      if (ok) refresh();
                    } else if (v == 'delete') {
                      try {
                        await ref
                            .read(communityRepositoryProvider)
                            .deleteChannel(ch.id);
                        refresh();
                      } on Exception catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('$e')));
                        }
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    if (!ch.isGeneral)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Returns true if a channel was created or updated.
Future<bool> _editChannel(
  BuildContext context,
  WidgetRef ref,
  String communityId,
  CommunityChannel? existing,
) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final desc = TextEditingController(text: existing?.description ?? '');
  var modsOnly = existing?.modsOnly ?? false;
  final isNew = existing == null;

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(isNew ? 'New channel' : 'Edit #${existing.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: isNew,
              maxLength: 60,
              decoration: const InputDecoration(
                labelText: 'Name',
                counterText: '',
              ),
            ),
            TextField(
              controller: desc,
              maxLength: 280,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Moderators only'),
              subtitle: const Text('Members can read but not post'),
              value: modsOnly,
              onChanged: (v) => setState(() => modsOnly = v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );

  if (saved != true || name.text.trim().isEmpty) return false;
  final repo = ref.read(communityRepositoryProvider);
  try {
    if (isNew) {
      final slug = name.text
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      await repo.createChannel(
        communityId,
        slug: slug.isEmpty ? 'channel' : slug,
        name: name.text.trim(),
        description: desc.text.trim(),
        modsOnly: modsOnly,
      );
    } else {
      await repo.updateChannel(
        existing.id,
        name: name.text.trim(),
        description: desc.text.trim(),
        modsOnly: modsOnly,
      );
    }
    return true;
  } on Exception catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    return false;
  }
}
