import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/messaging_repository.dart';
import 'chat_screen.dart';

/// The Messages tab: your conversations, with a separate section for requests
/// from people you don't follow. End-to-end encryption (MLS) arrives in
/// Phase 2.5 — until then messages are transport-encrypted only.
class MessagingScreen extends ConsumerWidget {
  const MessagingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final convos = ref.watch(conversationsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: convos.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) return const _Empty();
          final requests = list.where((c) => c.isRequest).toList();
          final active = list.where((c) => !c.isRequest).toList();
          return RefreshIndicator(
            onRefresh: () async =>
                ref.read(conversationsRevisionProvider.notifier).bump(),
            child: ListView(
              children: [
                if (requests.isNotEmpty) ...[
                  const _SectionHeader('Message requests'),
                  for (final c in requests) _ConversationTile(convo: c),
                  const Divider(),
                ],
                for (final c in active) _ConversationTile(convo: c),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No conversations yet.\n'
          'Open someone’s profile and tap Message to start one.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({required this.convo});
  final ConversationSummary convo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Text(
          convo.displayTitle.characters.first.toUpperCase(),
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
      title: Text(
        convo.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        convo.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: convo.unreadCount > 0
            ? TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600)
            : null,
      ),
      trailing: convo.unreadCount > 0
          ? Badge(label: Text('${convo.unreadCount}'))
          : null,
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChatScreen(
              conversationId: convo.id,
              title: convo.displayTitle,
              otherId: convo.otherId,
              isRequest: convo.isRequest,
            ),
          ),
        );
        ref.read(conversationsRevisionProvider.notifier).bump();
      },
    );
  }
}
