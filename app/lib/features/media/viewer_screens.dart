import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/viewer_repository.dart';
import '../../data/feed_repository.dart';
import '../feed/post_card.dart';
import '../media/watch_screen.dart';

/// A screen that displays all playlists owned by the current user.
class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(viewerRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My Playlists')),
      body: FutureBuilder<List<Playlist>>(
        future: repo.getPlaylists(publicOnly: false),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final playlists = snapshot.data ?? [];
          if (playlists.isEmpty) {
            return const Center(child: Text('No playlists found.'));
          }

          return ListView.builder(
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              return ListTile(
                leading: const Icon(Icons.playlist_add),
                title: Text(playlist.name),
                subtitle: Text(playlist.description ?? ''),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlaylistDetailScreen(playlist: playlist),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          // For now, just adding a dummy placeholder; real implementation would use a dialog.
          await repo.createPlaylist(name: 'New Playlist');
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// A screen that shows the content of a specific playlist.
class PlaylistDetailScreen extends ConsumerWidget {
  const PlaylistDetailScreen({super.key, required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(viewerRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: FutureBuilder<List<PlaylistEntry>>(
        future: repo.getPlaylistEntries(playlist.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final entries = snapshot.data ?? [];
          if (entries.isEmpty) {
            return const Center(child: Text('This playlist is empty.'));
          }

          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WatchScreen(post: entry.post),
                  ),
                ),
                child: PostCard(
                  post: entry.post,
                  tappable: false,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// A screen that displays the user's watch-later list.
class WatchLaterScreen extends ConsumerWidget {
  const WatchLaterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(viewerRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Watch Later')),
      body: FutureBuilder<List<FeedPost>>(
        future: repo.getWatchLaterPosts(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final posts = snapshot.data ?? [];
          if (posts.isEmpty) {
            return const Center(child: Text('Your watch-later list is empty.'));
          }

          return ListView.builder(
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final post = posts[index];
              return PostCard(
                post: post,
                tappable: false,
              );
            },
          );
        },
      ),
    );
  }
}

/// A screen that displays the "Up Next" queue.
class UpNextScreen extends ConsumerWidget {
  const UpNextScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // In a real implementation, this would come from a provider tracking current playback.
    return Scaffold(
      appBar: AppBar(title: const Text('Up Next')),
      body: const Center(child: Text('No upcoming media in your queue.')),
    );
  }
}
