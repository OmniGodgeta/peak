import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/messaging_repository.dart';
import '../../data/people_repository.dart';
import 'new_conversation_screen.dart';

final _membersProvider =
    FutureProvider.family<List<ConversationMember>, String>((
      ref,
      convId,
    ) async {
      ref.watch(conversationsRevisionProvider);
      return ref.watch(messagingRepositoryProvider).members(convId);
    });

class GroupSettingsScreen extends ConsumerStatefulWidget {
  const GroupSettingsScreen({
    super.key,
    required this.conversationId,
    required this.title,
  });
  final String conversationId;
  final String title;

  @override
  ConsumerState<GroupSettingsScreen> createState() =>
      _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends ConsumerState<GroupSettingsScreen> {
  bool _shareReceipts = false;

  Future<void> _addMembers() async {
    final picked = await Navigator.of(context).push<List<PersonSummary>>(
      MaterialPageRoute(
        builder: (_) => const NewConversationScreen(pickOnly: true),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final repo = ref.read(messagingRepositoryProvider);
    for (final p in picked) {
      try {
        await repo.addGroupMember(widget.conversationId, p.id);
      } on Exception {
        /* skip blocked / already-in */
      }
    }
    ref.read(conversationsRevisionProvider.notifier).bump();
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Leave group?'),
        content: const Text('You’ll stop receiving messages from this group.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(messagingRepositoryProvider)
        .leaveConversation(widget.conversationId);
    ref.read(conversationsRevisionProvider.notifier).bump();
    if (mounted) {
      Navigator.of(context)
        ..pop() // settings
        ..pop(); // chat
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(_membersProvider(widget.conversationId));
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Share read receipts'),
            subtitle: const Text(
              'Others see when you’ve read a message — only if they share too.',
            ),
            value: _shareReceipts,
            onChanged: (v) async {
              setState(() => _shareReceipts = v);
              await ref
                  .read(messagingRepositoryProvider)
                  .setShareReadReceipts(widget.conversationId, v);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.person_add_outlined),
            title: const Text('Add people'),
            onTap: _addMembers,
          ),
          members.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) =>
                Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
            data: (list) => Column(
              children: [
                for (final m in list)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(m.name.characters.first.toUpperCase()),
                    ),
                    title: Text(m.name),
                    subtitle: Text(m.fqHandle),
                  ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: Icon(
              Icons.logout,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              'Leave group',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: _leave,
          ),
        ],
      ),
    );
  }
}
