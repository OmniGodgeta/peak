import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/avatar.dart';
import '../../data/creator_repository.dart';
import '../../data/feed_repository.dart';
import '../../data/media_service.dart';
import 'watch_screen.dart';

class ChannelScreen extends ConsumerStatefulWidget {
  final String authorId;
  final String authorHandle;
  final String authorDisplayName;
  final String? authorAvatarPath;

  const ChannelScreen({
    super.key,
    required this.authorId,
    required this.authorHandle,
    required this.authorDisplayName,
    this.authorAvatarPath,
  });

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  bool? _isSubscribed;
  int? _subscriberCount;
  bool _isOptimisticSubscribing = false;

  bool get _isSelf =>
      Supabase.instance.client.auth.currentUser?.id == widget.authorId;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    if (_isSelf) {
      setState(() => _isSubscribed = false);
      return;
    }

    final repo = ref.read(creatorRepositoryProvider);
    final count = await repo.subscriberCount(widget.authorId);
    final subscribed = await repo.isSubscribed(widget.authorId);

    if (mounted) {
      setState(() {
        _subscriberCount = count;
        _isSubscribed = subscribed;
      });
    }
  }

  Future<void> _toggleSubscription() async {
    if (_isOptimisticSubscribing || _isSubscribed == null) return;

    final targetState = !_isSubscribed!;
    setState(() {
      _isSubscribed = targetState;
      _isOptimisticSubscribing = true;
    });

    try {
      final actualState = await ref
          .read(creatorRepositoryProvider)
          .toggleSubscription(widget.authorId);
      if (mounted) setState(() => _isSubscribed = actualState);
    } catch (e) {
      debugPrint('Error toggling subscription: $e');
      if (mounted) setState(() => _isSubscribed = !targetState);
    } finally {
      if (mounted) setState(() => _isOptimisticSubscribing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.authorDisplayName)),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 24),
            Center(
              child: AvatarCircle(
                name: widget.authorDisplayName,
                path: widget.authorAvatarPath,
                radius: 32,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.authorDisplayName,
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              '@${widget.authorHandle}',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            if (_subscriberCount != null)
              Text(
                '$_subscriberCount subscribers',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            const SizedBox(height: 16),
            if (!_isSelf)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: SizedBox(
                  width: double.infinity,
                  child: _isSubscribed == true
                      ? OutlinedButton(
                          onPressed: _isOptimisticSubscribing
                              ? null
                              : _toggleSubscription,
                          child: const Text('SUBSCRIBED'),
                        )
                      : FilledButton(
                          onPressed: _isOptimisticSubscribing
                              ? null
                              : _toggleSubscription,
                          child: const Text('SUBSCRIBE'),
                        ),
                ),
              ),
            const Divider(height: 48),
            _VideoList(authorId: widget.authorId),
          ],
        ),
      ),
    );
  }
}

class _VideoList extends ConsumerStatefulWidget {
  final String authorId;
  const _VideoList({required this.authorId});

  @override
  ConsumerState<_VideoList> createState() => _VideoListState();
}

class _VideoListState extends ConsumerState<_VideoList> {
  bool _isLoading = true;
  List<FeedPost> _posts = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    try {
      final posts = await ref
          .read(creatorRepositoryProvider)
          .getUserVideoPosts(widget.authorId);
      if (mounted) {
        setState(() {
          _posts = posts;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }
    if (_posts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('No videos yet.')),
      );
    }

    final mediaService = ref.watch(mediaServiceProvider);

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _posts.length,
      itemBuilder: (context, index) {
        final post = _posts[index];
        final posterPath = post.media.isNotEmpty
            ? post.media.first.posterPath
            : null;
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: posterPath == null
                ? Container(width: 100, height: 60, color: Colors.grey)
                : Image.network(
                    mediaService.resolveUrl(posterPath),
                    width: 100,
                    height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        Container(width: 100, height: 60, color: Colors.grey),
                  ),
          ),
          title: Text(
            post.title?.isNotEmpty == true ? post.title! : post.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => WatchScreen(post: post)),
          ),
        );
      },
    );
  }
}
