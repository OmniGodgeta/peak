import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/feed_repository.dart';
import '../feed/post_body.dart';
import '../feed/post_media_view.dart';
import '../feed/thread_screen.dart';
import '../profile/user_profile_screen.dart';
import '../../data/media_service.dart';
import '../../data/playback_persistence_service.dart';
import '../../data/creator_repository.dart';
import 'channel_screen.dart';

/// The watch page for one video post: a large auto-loading player, then title,
/// uploader, description, and a jump into the discussion (the post's thread).
class WatchScreen extends ConsumerStatefulWidget {
  const WatchScreen({super.key, required this.post});
  final FeedPost post;

  @override
  ConsumerState<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends ConsumerState<WatchScreen> {
  Duration? _savedPosition;
  List<FeedPost>? _upNextPosts;
  bool _isLoadingUpNext = false;

  @override
  void initState() {
    super.initState();
    _loadSavedPosition();
    _fetchUpNext();
  }

  Future<void> _loadSavedPosition() async {
    final pos = await ref
        .read(playbackPersistenceServiceProvider)
        .getPosition(widget.post.id);
    if (mounted) setState(() => _savedPosition = pos);
  }

  Future<void> _fetchUpNext() async {
    setState(() => _isLoadingUpNext = true);
    try {
      final posts = await ref
          .read(creatorRepositoryProvider)
          .getUserVideoPosts(widget.post.authorId);
      // Filter out the current post
      final others = posts
          .where((p) => p.id != widget.post.id)
          .take(6)
          .toList();
      if (mounted) {
        setState(() {
          _upNextPosts = others;
          _isLoadingUpNext = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching up next: $e');
      if (mounted) setState(() => _isLoadingUpNext = false);
    }
  }

  Future<void> _saveCurrentPosition(Duration position) async {
    await ref
        .read(playbackPersistenceServiceProvider)
        .savePosition(widget.post.id, position);
  }

  @override
  Widget build(BuildContext context) {
    final mediaService = ref.watch(mediaServiceProvider);
    final scheme = Theme.of(context).colorScheme;
    PostMedia? video;
    for (final m in widget.post.media) {
      if (m.isVideo) {
        video = m;
        break;
      }
    }
    final name = widget.post.authorDisplayName.isNotEmpty
        ? widget.post.authorDisplayName
        : widget.post.authorHandle;
    final title = widget.post.title?.trim();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch'),
        actions: [
          IconButton(
            icon: const Icon(Icons.subscriptions_outlined),
            tooltip: 'View channel',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChannelScreen(
                  authorId: widget.post.authorId,
                  authorHandle: widget.post.authorHandle,
                  authorDisplayName: widget.post.authorDisplayName.isNotEmpty
                      ? widget.post.authorDisplayName
                      : widget.post.authorHandle,
                  authorAvatarPath: widget.post.authorAvatarPath,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Copy link',
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: videoShareLink(widget.post.id)),
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
                    url: mediaService.resolveUrl(video.storagePath),
                    posterUrl: video.posterPath == null
                        ? null
                        : mediaService.resolveUrl(video.posterPath!),
                    aspectRatio: video.aspectRatio,
                    maxHeight: 520,
                    autoLoad: true,
                    initialPosition: _savedPosition,
                    onPositionChanged: _saveCurrentPosition,
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
              path: widget.post.authorAvatarPath,
              radius: 18,
            ),
            title: Text(name),
            subtitle: Text(
              '@${widget.post.authorHandle} · ${widget.post.reactionCount} reactions',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    UserProfileScreen(handle: widget.post.authorHandle),
              ),
            ),
          ),
          if (widget.post.body.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: PostBody(text: widget.post.body.trim()),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.forum_outlined),
              label: Text(
                widget.post.replyCount == 0
                    ? 'Start the discussion'
                    : 'View discussion (${widget.post.replyCount})',
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ThreadScreen(rootId: widget.post.id),
                ),
              ),
            ),
          ),
          Divider(color: scheme.outlineVariant, height: 1),
          if (_upNextPosts != null && _upNextPosts!.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                'UP NEXT',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ..._upNextPosts!.map(
              (post) => ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    mediaService.resolveUrl(post.media.first.posterPath ?? ''),
                    width: 100,
                    height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        Container(width: 100, height: 60, color: Colors.grey),
                  ),
                ),
                title: Text(
                  post.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => WatchScreen(post: post)),
                ),
              ),
            ),
          ],
          if (_isLoadingUpNext)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
