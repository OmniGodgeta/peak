import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/custom_feed_repository.dart';
import '../../data/feed_repository.dart';
import '../../data/notification_repository.dart';
import '../../data/story_repository.dart';
import '../compose/compose_screen.dart';
import '../home/notifications_screen.dart';
import '../media/watch_screen.dart';
import '../stories/stories_strip.dart';
import 'custom_feeds_screen.dart';
import 'post_card.dart';

/// Home. Built-in feeds: **Latest** (everyone you follow) and **Friends first**
/// (people who follow you back). Plus any custom feeds you've made. No infinite
/// scroll — after a page you get a "You're caught up" card.
class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key, this.forcedKind});

  final FeedKind? forcedKind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = forcedKind ?? ref.watch(selectedFeedProvider);
    final activeCustom = ref.watch(activeCustomFeedProvider);
    final customFeeds =
        ref.watch(myCustomFeedsProvider).asData?.value ?? const [];

    final feed = activeCustom != null
        ? ref.watch(customFeedPostsProvider(activeCustom))
        : ref.watch(feedProvider);

    void invalidateFeed() {
      if (activeCustom != null) {
        ref.invalidate(customFeedPostsProvider(activeCustom));
      } else {
        ref.invalidate(feedProvider);
      }
    }

    // Handle the display value for the header dropdown.
    // If we are in a forced mode, we want to show it but perhaps disable changing it.
    // For simplicity, we'll show it.
    final String value = activeCustom != null
        ? 'cf:$activeCustom'
        : switch (kind) {
            FeedKind.friendsFirst => 'friends',
            FeedKind.local => 'local',
            FeedKind.latest => 'latest',
            FeedKind.recommendations => 'recommendations',
            _ => 'latest',
          };

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Notices',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const NotificationsScreen(),
              ),
            ),
            icon: Badge(
              isLabelVisible:
                  (ref.watch(unreadNoticesProvider).asData?.value ?? 0) > 0,
              label: Text(
                '${ref.watch(unreadNoticesProvider).asData?.value ?? 0}',
              ),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
        ],
        title: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            onChanged: forcedKind != null
                ? null
                : (v) {
                    if (v == null) return;
                    if (v == 'manage') {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const CustomFeedsScreen(),
                        ),
                      );
                      return;
                    }
                    if (v == 'latest') {
                      ref.read(activeCustomFeedProvider.notifier).set(null);
                      ref
                          .read(selectedFeedProvider.notifier)
                          .set(FeedKind.latest);
                    } else if (v == 'friends') {
                      ref.read(activeCustomFeedProvider.notifier).set(null);
                      ref
                          .read(selectedFeedProvider.notifier)
                          .set(FeedKind.friendsFirst);
                    } else if (v == 'local') {
                      ref.read(activeCustomFeedProvider.notifier).set(null);
                      ref
                          .read(selectedFeedProvider.notifier)
                          .set(FeedKind.local);
                    } else if (v == 'recommendations') {
                      ref.read(activeCustomFeedProvider.notifier).set(null);
                      ref
                          .read(selectedFeedProvider.notifier)
                          .set(FeedKind.recommendations);
                    } else if (v.startsWith('cf:')) {
                      ref
                          .read(activeCustomFeedProvider.notifier)
                          .set(v.substring(3));
                    }
                  },
            items: [
              const DropdownMenuItem(value: 'latest', child: Text('Latest')),
              const DropdownMenuItem(
                value: 'friends',
                child: Text('Friends first'),
              ),
              const DropdownMenuItem(value: 'local', child: Text('Local')),
              const DropdownMenuItem(
                value: 'recommendations',
                child: Text('For You'),
              ),
              for (final f in customFeeds)
                DropdownMenuItem(value: 'cf:${f.id}', child: Text(f.name)),
              const DropdownMenuItem(
                value: 'manage',
                child: Text('Manage feeds…'),
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
        error: (e, _) => _ErrorState(message: '$e', onRetry: invalidateFeed),
        data: (posts) {
          return RefreshIndicator(
            onRefresh: () async {
              invalidateFeed();
              ref.invalidate(storyTrayProvider);
              ref.invalidate(videosProvider(''));
            },
            child: ListView(
              children: [
                const StoriesStrip(),
                const _VideoShelf(),
                const Divider(height: 1),
                if (posts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: _EmptyFeed(
                      friendsFirst:
                          activeCustom == null && kind == FeedKind.friendsFirst,
                      local: activeCustom == null && kind == FeedKind.local,
                      custom: activeCustom != null,
                    ),
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

/// Newest public videos, pinned above the chronological feed so a photo-heavy
/// follow list does not hide them.
class _VideoShelf extends ConsumerWidget {
  const _VideoShelf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videos = ref.watch(videosProvider(''));
    return videos.maybeWhen(
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final repo = ref.watch(feedRepositoryProvider);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                'Videos',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            SizedBox(
              height: 148,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: list.length.clamp(0, 12),
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final post = list[i];
                  PostMedia? video;
                  for (final m in post.media) {
                    if (m.isVideo) {
                      video = m;
                      break;
                    }
                  }
                  final poster = video?.posterPath;
                  final title = post.title?.trim().isNotEmpty == true
                      ? post.title!.trim()
                      : post.authorHandle;
                  return SizedBox(
                    width: 220,
                    child: InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => WatchScreen(post: post),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: AspectRatio(
                              aspectRatio: 16 / 9,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Container(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                  ),
                                  if (poster != null)
                                    Image.network(
                                      repo.mediaUrl(poster),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) =>
                                          const SizedBox.shrink(),
                                    ),
                                  const Center(
                                    child: Icon(
                                      Icons.play_circle_fill,
                                      color: Colors.white70,
                                      size: 36,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
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
  const _EmptyFeed({
    this.friendsFirst = false,
    this.local = false,
    this.custom = false,
  });
  final bool friendsFirst;
  final bool local;
  final bool custom;

  @override
  Widget build(BuildContext context) {
    final (title, hint) = custom
        ? (
            'Nothing matches this feed yet.',
            'Adjust its rules from Manage feeds, or wait for matching posts.',
          )
        : local
        ? (
            'Nothing public here yet.',
            'Local shows every public post on Peak. Be the first — tap the '
                'pencil.',
          )
        : friendsFirst
        ? (
            'No posts from your friends yet.',
            'Friends first shows only people who follow you back. '
                'Switch to Latest for everyone you follow you back.',
          )
        : (
            'Your feed is empty.',
            'Follow some people, or post something to one of your circles.',
          );
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title),
            const SizedBox(height: 8),
            Text(
              hint,
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
