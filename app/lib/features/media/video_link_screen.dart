import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feed_repository.dart';
import '../feed/thread_screen.dart';
import 'watch_screen.dart';

/// Resolves a shared `peak.social/v/<id>` link: loads the post and shows the
/// watch page (or the thread, if it's not actually a video).
class VideoLinkScreen extends ConsumerWidget {
  const VideoLinkScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final post = ref.watch(postByIdProvider(id));
    return post.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('$e')),
      ),
      data: (p) {
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('That post is gone.')),
          );
        }
        final hasVideo = p.media.any((m) => m.isVideo);
        return hasVideo ? WatchScreen(post: p) : ThreadScreen(rootId: p.id);
      },
    );
  }
}
