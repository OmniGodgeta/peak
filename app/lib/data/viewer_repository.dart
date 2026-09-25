import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'feed_repository.dart';
import 'supabase_providers.dart';

/// Represents a playlist created by a user.
class Playlist {
  const Playlist({
    required this.id,
    required this.ownerId,
    required this.name,
    this.description,
    this.isPublic = true,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String ownerId;
  final String name;
  final String? description;
  final bool isPublic;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Playlist.fromMap(Map<String, dynamic> m) => Playlist(
    id: m['id'] as String,
    ownerId: m['owner_id'] as String,
    name: m['name'] as String,
    description: m['description'] as String?,
    isPublic: (m['is_public'] as bool?) ?? true,
    createdAt: m['created_at'] == null
        ? null
        : DateTime.parse(m['created_at'] as String),
    updatedAt: m['updated_at'] == null
        ? null
        : DateTime.parse(m['updated_at'] as String),
  );
}

/// Represents an item in a playlist.
class PlaylistItem {
  const PlaylistItem({
    required this.id,
    required this.playlistId,
    required this.mediaId,
    this.sortOrder = 0,
    this.addedAt,
  });

  final String id;
  final String playlistId;
  final String mediaId;
  final int sortOrder;
  final DateTime? addedAt;

  factory PlaylistItem.fromMap(Map<String, dynamic> m) => PlaylistItem(
    id: m['id'] as String,
    playlistId: m['playlist_id'] as String,
    mediaId: m['media_id'] as String,
    sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
    addedAt: m['added_at'] == null
        ? null
        : DateTime.parse(m['added_at'] as String),
  );
}

/// Manages viewer-specific features like playlists and watch-later.
class ViewerRepository {
  ViewerRepository(this._db, this._userId);
  final SupabaseClient _db;
  final String _userId;

  // --- Playlists ---

  Future<List<Playlist>> getPlaylists({bool publicOnly = false}) async {
    var query = _db.from('playlist').select();
    if (publicOnly) {
      query = query.or('is_public.eq.true,owner_id.eq.$_userId');
    }
    final rows = await query;
    return (rows as List)
        .map((e) => Playlist.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createPlaylist({
    required String name,
    String? description,
    bool isPublic = true,
  }) async {
    await _db.from('playlist').insert({
      'owner_id': _userId,
      'name': name,
      'description': description,
      'is_public': isPublic,
    });
  }

  Future<void> updatePlaylist({
    required String playlistId,
    required String name,
    String? description,
    bool? isPublic,
  }) async {
    final Map<String, dynamic> patch = {'name': name};
    if (description != null) patch['description'] = description;
    if (isPublic != null) patch['is_public'] = isPublic;
    await _db.from('playlist').update(patch).eq('id', playlistId);
  }

  Future<void> deletePlaylist(String playlistId) async {
    await _db.from('playlist').delete().eq('id', playlistId);
  }

  // --- Playlist Items ---

  // `post:media.post_id(...)` used to be attempted here as a sibling embed
  // of `media:media_id(...)` — that dotted path isn't valid PostgREST embed
  // syntax, and even fixed, the raw `post` table has no author_handle /
  // reaction_count / viewer_reacted columns (those are computed by the
  // post_thread function, not stored) — so FeedPost.fromMap would still
  // fail on whatever came back. Fetch the media row, then resolve each
  // post the same way FeedRepository.byId() does: via post_thread.
  Future<List<PlaylistEntry>> getPlaylistEntries(String playlistId) async {
    final rows = await _db
        .from('playlist_item')
        .select('''
          id,
          sort_order,
          added_at,
          media:media_id (
            post_id, kind, storage_path, poster_path, alt_text, width, height, duration_ms
          )
        ''')
        .eq('playlist_id', playlistId)
        .order('sort_order', ascending: true);

    final entries = <PlaylistEntry>[];
    for (final row in rows as List) {
      final m = row as Map<String, dynamic>;
      final mediaData = m['media'] as Map<String, dynamic>;
      final postId = mediaData['post_id'] as String;
      final postRows = await _db.rpc('post_thread', params: {'p_root': postId});
      final postList = postRows as List;
      if (postList.isEmpty) continue; // post deleted or no longer visible
      entries.add(
        PlaylistEntry(
          id: m['id'] as String,
          sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
          addedAt: m['added_at'] == null
              ? null
              : DateTime.parse(m['added_at'] as String),
          media: PostMedia.fromMap(mediaData),
          post: FeedPost.fromMap(postList.first as Map<String, dynamic>),
        ),
      );
    }
    return entries;
  }

  Future<void> addMediaToPlaylist(String playlistId, String mediaId) async {
    await _db.from('playlist_item').insert({
      'playlist_id': playlistId,
      'media_id': mediaId,
    });
  }

  Future<void> removeMediaFromPlaylist(
    String playlistId,
    String mediaId,
  ) async {
    await _db
        .from('playlist_item')
        .delete()
        .eq('playlist_id', playlistId)
        .eq('media_id', mediaId);
  }

  Future<List<FeedPost>> getWatchLaterPosts() async {
    final mediaIds = await getWatchLaterMediaIds();
    if (mediaIds.isEmpty) return [];

    final rows = await _db
        .from('post_media')
        .select('''
          id,
          post_id,
          kind, storage_path, poster_path, alt_text, width, height, duration_ms
        ''')
        .filter('id', 'in', mediaIds);

    final postIds = (rows as List).map((e) => e['post_id'] as String).toSet();
    if (postIds.isEmpty) return [];

    final posts = <FeedPost>[];
    for (final id in postIds) {
      final thread = await _db.rpc('post_thread', params: {'p_root': id});
      final list = (thread as List)
          .map((e) => FeedPost.fromMap(e as Map<String, dynamic>))
          .toList();
      if (list.isNotEmpty) posts.add(list.first);
    }
    return posts;
  }

  Future<List<String>> getWatchLaterMediaIds() async {
    final rows = await _db
        .from('watch_later')
        .select('media_id')
        .eq('user_id', _userId);
    return (rows as List).map((e) => e['media_id'] as String).toList();
  }

  Future<void> addToWatchLater(String mediaId) async {
    try {
      await _db.from('watch_later').insert({
        'user_id': _userId,
        'media_id': mediaId,
      });
    } catch (e) {
      // Ignore if already exists (duplicate error)
    }
  }

  Future<void> removeFromWatchLater(String mediaId) async {
    await _db
        .from('watch_later')
        .delete()
        .eq('user_id', _userId)
        .eq('media_id', mediaId);
  }
}

/// A wrapper to combine a PlaylistItem with the resolved Post/Media data.
class PlaylistEntry {
  const PlaylistEntry({
    required this.id,
    required this.sortOrder,
    required this.addedAt,
    required this.media,
    required this.post,
  });

  final String id;
  final int sortOrder;
  final DateTime? addedAt;
  final PostMedia media;
  final FeedPost post;

  factory PlaylistEntry.fromMap(Map<String, dynamic> m) {
    final mediaData = m['media'] as Map<String, dynamic>;
    final postData = m['post'] as Map<String, dynamic>;

    return PlaylistEntry(
      id: m['id'] as String,
      sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
      addedAt: m['added_at'] == null
          ? null
          : DateTime.parse(m['added_at'] as String),
      media: PostMedia.fromMap(mediaData),
      post: FeedPost.fromMap(postData),
    );
  }
}

final viewerRepositoryProvider = Provider<ViewerRepository>((ref) {
  final supabase = ref.watch(supabaseProvider);
  final user = supabase.auth.currentUser;
  if (user == null) throw Exception('User not authenticated');
  return ViewerRepository(supabase, user.id);
});
