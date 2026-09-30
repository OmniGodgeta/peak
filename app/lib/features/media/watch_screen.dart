import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/avatar.dart';
import '../../data/feed_repository.dart';
import '../feed/post_body.dart';
import '../feed/post_media_view.dart';
import '../feed/thread_screen.dart';
import '../profile/user_profile_screen.dart';
import '../../data/media_service.dart';
import '../../data/playback_persistence_service.dart';
import '../../data/creator_repository.dart';
import '../profile/creator_video_editor_sheet.dart' show formatCueTime;
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
  // The player waits for this so it can start where the viewer left off.
  bool _positionLoaded = false;
  VideoExtras? _extras;
  VideoPlayerController? _controller;
  List<FeedPost>? _upNextPosts;
  bool _isLoadingUpNext = false;

  @override
  void initState() {
    super.initState();
    _loadSavedPosition();
    _loadExtras();
    _fetchUpNext();
  }

  Future<void> _loadExtras() async {
    try {
      final extras = await ref
          .read(creatorRepositoryProvider)
          .videoExtras(widget.post.id);
      if (mounted) setState(() => _extras = extras);
    } catch (e) {
      debugPrint('Error loading chapters: $e');
    }
  }

  void _seekTo(Duration t) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    c.seekTo(t);
    if (!c.value.isPlaying) c.play();
  }

  Future<void> _loadSavedPosition() async {
    Duration? pos;
    try {
      pos = await ref
          .read(playbackPersistenceServiceProvider)
          .getPosition(widget.post.id);
    } catch (_) {
      pos = null;
    }
    if (mounted) {
      setState(() {
        _savedPosition = pos;
        _positionLoaded = true;
      });
    }
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
                : !_positionLoaded
                ? const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : PostVideo(
                    url: mediaService.resolveUrl(video.storagePath),
                    hlsUrl: hlsFor(video),
                    posterUrl: video.posterPath == null
                        ? null
                        : mediaService.resolveUrl(video.posterPath!),
                    aspectRatio: video.aspectRatio,
                    maxHeight: 520,
                    autoLoad: true,
                    initialPosition: _savedPosition,
                    onPositionChanged: _saveCurrentPosition,
                    captions: _extras?.captions ?? const [],
                    onControllerReady: (c) => _controller = c,
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
          if (_extras != null && _extras!.chapters.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Chapters',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final ch in _extras!.chapters)
              ListTile(
                dense: true,
                leading: Text(
                  formatCueTime(ch.start),
                  style: TextStyle(
                    color: scheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                title: Text(ch.text),
                onTap: () => _seekTo(ch.start),
              ),
          ],
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
