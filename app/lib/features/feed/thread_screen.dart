import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feed_repository.dart';
import '../../data/federation_repository.dart';
import '../federation/remote_note_card.dart';
import '../compose/compose_screen.dart';
import 'post_card.dart';

final threadProvider = FutureProvider.family<List<FeedPost>, String>((
  ref,
  rootId,
) async {
  return ref.watch(feedRepositoryProvider).thread(rootId);
});

/// A post and its replies. The root sits at the top; replies are indented by
/// depth (capped so deep threads stay readable).
class ThreadScreen extends ConsumerWidget {
  const ThreadScreen({super.key, required this.rootId});
  final String rootId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thread = ref.watch(threadProvider(rootId));

    return Scaffold(
      appBar: AppBar(title: const Text('Thread')),
      floatingActionButton: thread.asData?.value.isNotEmpty == true
          ? FloatingActionButton(
              onPressed: () async {
                final root = thread.asData!.value.first;
                final posted = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => ComposeScreen(replyTo: root),
                  ),
                );
                if (posted == true) ref.invalidate(threadProvider(rootId));
              },
              child: const Icon(Icons.reply),
            )
          : null,
      body: thread.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (posts) {
          if (posts.isEmpty) {
            return const Center(child: Text('This thread is not available.'));
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(threadProvider(rootId));
              ref.invalidate(remoteRepliesProvider(rootId));
            },
            child: ListView(
              children: [
                for (final post in posts) ...[
                  Padding(
                    padding: EdgeInsets.only(
                      left: (post.depth.clamp(0, 3)) * 16.0,
                    ),
                    child: PostCard(post: post, tappable: post.depth > 0),
                  ),
                  const Divider(height: 1),
                ],
                // Replies from people on other servers (federation).
                ...ref
                        .watch(remoteRepliesProvider(rootId))
                        .asData
                        ?.value
                        .expand(
                          (n) => [
                            Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: RemoteNoteCard(note: n),
                            ),
                            const Divider(height: 1),
                          ],
                        ) ??
                    const <Widget>[],
              ],
            ),
          );
        },
      ),
    );
  }
}
