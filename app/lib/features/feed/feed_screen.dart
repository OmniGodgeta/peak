import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feed_repository.dart';
import '../../data/story_repository.dart';
import '../compose/compose_screen.dart';
import '../stories/stories_strip.dart';
import 'post_card.dart';

/// Home. Phase 1 ships **Latest** (reverse-chronological) and **Friends first**;
/// custom feeds arrive in Phase 5. No infinite autoplaying scroll — after a page
/// you get a "You're caught up" card.
class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedProvider);
    final kind = ref.watch(selectedFeedProvider);

    return Scaffold(
      appBar: AppBar(
        title: DropdownButtonHideUnderline(
          child: DropdownButton<FeedKind>(
            value: kind,
            onChanged: (v) => v == null
                ? null
                : ref.read(selectedFeedProvider.notifier).set(v),
            items: const [
              DropdownMenuItem(value: FeedKind.latest, child: Text('Latest')),
              DropdownMenuItem(
                value: FeedKind.friendsFirst,
                child: Text('Friends first'),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const ComposeScreen())),
        child: const Icon(Icons.edit),
      ),
      body: feed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(
          message: '$e',
          onRetry: () => ref.invalidate(feedProvider),
        ),
        data: (posts) {
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(feedProvider);
              ref.invalidate(storyTrayProvider);
            },
            child: ListView(
              children: [
                const StoriesStrip(),
                const Divider(height: 1),
                if (posts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 80),
                    child: _EmptyFeed(),
                  )
                else ...[
                  for (final p in posts) ...[
                    PostCard(post: p),
                    const Divider(height: 1),
                  ],
                  const _CaughtUp(),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CaughtUp extends StatelessWidget {
  const _CaughtUp();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(
            Icons.check_circle_outline,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 8),
          const Text("You're caught up."),
          const SizedBox(height: 4),
          Text(
            'No infinite scroll here. Come back later, or check Discover.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your feed is empty.'),
            const SizedBox(height: 8),
            Text(
              'Follow some people, or post something to one of your circles.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
