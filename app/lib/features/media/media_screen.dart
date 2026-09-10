import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/feed_repository.dart';
import '../compose/compose_screen.dart';
import 'watch_screen.dart';

/// The Media tab: a video destination. Browse the newest videos across the
/// instance, or search them (full-text over title + description). Tapping a
/// card opens the watch page.
class MediaScreen extends ConsumerStatefulWidget {
  const MediaScreen({super.key});

  @override
  ConsumerState<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends ConsumerState<MediaScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final videos = ref.watch(videosProvider(_query));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search videos',
              prefixIcon: const Icon(Icons.search),
              border: InputBorder.none,
              filled: false,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.videocam_outlined),
        label: const Text('Post a video'),
        onPressed: () async {
          final posted = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => const ComposeScreen(startWithVideo: true),
            ),
          );
          if (posted == true) ref.invalidate(videosProvider(_query));
        },
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(videosProvider(_query)),
        child: videos.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              const SizedBox(height: 80),
              Center(child: Text('$e')),
            ],
          ),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 100),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _query.trim().isEmpty
                            ? 'No videos yet.\nPost one from the composer — tap '
                                  'the pencil, then Video.'
                            : 'No videos match “$_query”.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (_, i) => _VideoCard(post: list[i]),
            );
          },
        ),
      ),
    );
  }
}

class _VideoCard extends ConsumerWidget {
  const _VideoCard({required this.post});
  final FeedPost post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(feedRepositoryProvider);
    final scheme = Theme.of(context).colorScheme;
    PostMedia? video;
    for (final m in post.media) {
      if (m.isVideo) {
        video = m;
        break;
      }
    }
    final poster = video?.posterPath;
    final heading = post.title?.trim().isNotEmpty == true
        ? post.title!.trim()
        : (post.body.trim().isEmpty
              ? '(untitled video)'
              : post.body.replaceAll('\n', ' ').trim());
    final name = post.authorDisplayName.isNotEmpty
        ? post.authorDisplayName
        : post.authorHandle;

    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => WatchScreen(post: post))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: scheme.surfaceContainerHighest),
                    if (poster != null)
                      Image.network(
                        repo.mediaUrl(poster),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    const Center(
                      child: Icon(
                        Icons.play_circle_fill,
                        size: 46,
                        color: Colors.white70,
                        shadows: [Shadow(blurRadius: 10)],
                      ),
                    ),
                    if (video?.durationMs != null)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            child: Text(
                              _fmtDuration(video!.durationMs!),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AvatarCircle(
                  name: name,
                  path: post.authorAvatarPath,
                  radius: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        heading,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$name · ${post.replyCount} '
                        '${post.replyCount == 1 ? 'comment' : 'comments'}',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtDuration(int ms) {
  final s = (ms / 1000).round();
  final m = s ~/ 60;
  final rem = s % 60;
  return '$m:${rem.toString().padLeft(2, '0')}';
}
