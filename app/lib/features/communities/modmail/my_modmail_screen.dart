import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/modmail_repository.dart';
import 'modmail_thread_screen.dart';

/// The member's own modmail threads, across every community.
class MyModmailScreen extends ConsumerWidget {
  const MyModmailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threads = ref.watch(myModmailThreadsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Moderator messages')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myModmailThreadsProvider),
        child: threads.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        "You haven't messaged any moderators.\n"
                        'Open a thread from a community page.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = list[i];
                return ListTile(
                  title: Text(
                    t.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${t.communityName ?? ""} · ${t.lastSnippet ?? ""}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: t.isOpen
                      ? (t.lastFromMod
                            ? const Icon(
                                Icons.mark_email_unread_outlined,
                                size: 18,
                              )
                            : null)
                      : const Text('closed', style: TextStyle(fontSize: 11)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ModmailThreadScreen(thread: t, viewerIsMod: false),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
