import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// Counts on the signed-in account's own posts. Null when analytics are off,
/// so the screen cannot show numbers the person did not ask for.
class ReachStats {
  const ReachStats({
    required this.optedIn,
    this.posts,
    this.likes,
    this.replies,
    this.reposts,
    this.activeBoosts,
  });

  final bool optedIn;
  final int? posts;
  final int? likes;
  final int? replies;
  final int? reposts;
  final int? activeBoosts;

  factory ReachStats.fromMap(Map<String, dynamic> m) => ReachStats(
    optedIn: (m['opted_in'] as bool?) ?? false,
    posts: (m['posts'] as num?)?.toInt(),
    likes: (m['likes'] as num?)?.toInt(),
    replies: (m['replies'] as num?)?.toInt(),
    reposts: (m['reposts'] as num?)?.toInt(),
    activeBoosts: (m['active_boosts'] as num?)?.toInt(),
  );
}

class CreatorRepository {
  CreatorRepository(this._db);
  final SupabaseClient _db;

  Future<ReachStats> stats() async {
    final rows = await _db.rpc('my_post_stats');
    final list = rows as List;
    if (list.isEmpty) return const ReachStats(optedIn: false);
    return ReachStats.fromMap(list.first as Map<String, dynamic>);
  }

  Future<void> setOptIn(bool on) async {
    await _db.rpc('set_analytics_opt_in', params: {'p_on': on});
  }

  Future<void> boost(String postId) async {
    await _db.rpc('boost_my_post', params: {'p_post_id': postId});
  }

  Future<void> unboost(String postId) async {
    await _db.rpc('unboost_my_post', params: {'p_post_id': postId});
  }

  /// Fetches the raw video rows for a specific author via existing RPC.
  /// Returns items with keys: media_id, post_id, storage_path, poster_path, etc.
  Future<List<Map<String, dynamic>>> getUserVideos(String authorId, {int limit = 30}) async {
    final rows = await _db.rpc('get_user_videos', params: {
      'p_author_id': authorId,
      'p_limit': limit,
    });
    return (rows as List).map((e) => e as Map<String, dynamic>).toList();
  }

  /// Deletes old chapters and inserts new ones for a given media_id.
  Future<void> saveChapters(String mediaId, List<Map<String, dynamic>> chapters) async {
    await _db.from('post_chapters').delete().eq('media_id', mediaId);
    if (chapters.isNotEmpty) {
      final data = chapters.map((c) => {
        'media_id': mediaId,
        'label': c['label'],
        'start_ms': c['start_ms'],
        'end_ms': c['end_ms'],
      }).toList();
      await _db.from('post_chapters').insert(data);
    }
  }

  /// Deletes old subtitles and inserts new ones for a given media_id.
  Future<void> saveSubtitles(String mediaId, List<Map<String, dynamic>> subtitles) async {
    await _db.from('post_subtitles').delete().eq('media_id', mediaId);
    if (subtitles.isNotEmpty) {
      final data = subtitles.map((s) => {
        'media_id': mediaId,
        'language': s['language'] ?? 'en',
        'text': s['text'],
        'start_ms': s['start_ms'],
        'end_ms': s['end_ms'],
      }).toList();
      await _db.from('post_subtitles').insert(data);
    }
  }

  /// Updates the poster path in post_media.
  Future<void> updatePosterPath(String mediaId, String path) async {
    await _db.from('post_media').update({'poster_path': path}).eq('id', mediaId);
  }
}

final creatorRepositoryProvider = Provider<CreatorRepository>((ref) {
  return CreatorRepository(ref.watch(supabaseProvider));
});

// New provider for user videos in profile context
final userVideosProvider = FutureProvider.family<List<Map<String, dynamic>>, String>((ref, authorId) async {
  return ref.watch(creatorRepositoryProvider).getUserVideos(authorId);
});

final reachStatsProvider = FutureProvider<ReachStats>((ref) async {
  return ref.watch(creatorRepositoryProvider).stats();
});
