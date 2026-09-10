import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/feed_repository.dart';
import '../feed/post_media_view.dart';
import '../feed/thread_screen.dart';
import '../profile/user_profile_screen.dart';

/// The watch page for one video post: a large auto-loading player, then title,
/// uploader, description, and a jump into the discussion (the post's thread).
class WatchScreen extends ConsumerWidget {
  const WatchScreen({super.key, required this.post});
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
    final name = post.authorDisplayName.isNotEmpty
        ? post.authorDisplayName
        : post.authorHandle;
    final title = post.title?.trim();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Copy link',
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: videoShareLink(post.id)),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Link copied')));
              }
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          Container(
            color: Colors.black,
            child: video == null
                ? const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(
                      child: Icon(Icons.videocam_off, color: Colors.white54),
                    ),
                  )
                : PostVideo(
                    url: repo.mediaUrl(video.storagePath),
                    posterUrl: video.posterPath == null
                        ? null
                        : repo.mediaUrl(video.posterPath!),
                    aspectRatio: video.aspectRatio,
                    maxHeight: 520,
                    autoLoad: true,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              title?.isNotEmpty == true ? title! : name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          ListTile(
            leading: AvatarCircle(
              name: name,
              path: post.authorAvatarPath,
              radius: 18,
            ),
            title: Text(name),
            subtitle: Text(
              '@${post.authorHandle} · ${post.reactionCount} reactions',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => UserProfileScreen(handle: post.authorHandle),
              ),
            ),
          ),
          if (post.body.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(post.body.trim()),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.forum_outlined),
              label: Text(
                post.replyCount == 0
                    ? 'Start the discussion'
                    : 'View discussion (${post.replyCount})',
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ThreadScreen(rootId: post.id),
                ),
              ),
            ),
          ),
          Divider(color: scheme.outlineVariant, height: 1),
        ],
      ),
    );
  }
}
