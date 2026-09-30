import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'feed_repository.dart';
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

/// One timed span of a video: a chapter or a caption line.
class VideoCue {
  const VideoCue({required this.text, required this.start, required this.end});
  final String text;
  final Duration start;
  final Duration end;

  bool covers(Duration t) => t >= start && t < end;
}

class VideoExtras {
  const VideoExtras({
    required this.mediaId,
    required this.chapters,
    required this.captions,
  });

  final String mediaId;
  final List<VideoCue> chapters;
  final List<VideoCue> captions;

  factory VideoExtras.fromMap(Map<String, dynamic> m) {
    List<VideoCue> cues(Object? list, String key) => [
      for (final e in (list as List? ?? const []))
        VideoCue(
          text: (e as Map)[key] as String? ?? '',
          start: Duration(milliseconds: (e['start_ms'] as num).toInt()),
          end: Duration(milliseconds: (e['end_ms'] as num).toInt()),
        ),
    ];
    return VideoExtras(
      mediaId: m['media_id'] as String,
      chapters: cues(m['chapters'], 'label'),
      captions: cues(m['captions'], 'text'),
    );
  }
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
  Future<List<Map<String, dynamic>>> getUserVideos(
    String authorId, {
    int limit = 30,
  }) async {
    final rows = await _db.rpc(
      'get_user_videos',
      params: {'p_author_id': authorId, 'p_limit': limit},
    );
    return (rows as List).map((e) => e as Map<String, dynamic>).toList();
  }

  /// Deletes old chapters and inserts new ones for a given media_id.
  Future<void> saveChapters(
    String mediaId,
    List<Map<String, dynamic>> chapters,
  ) async {
    await _db.from('post_chapters').delete().eq('media_id', mediaId);
    if (chapters.isNotEmpty) {
      final data = chapters
          .map(
            (c) => {
              'media_id': mediaId,
              'label': c['label'],
              'start_ms': c['start_ms'],
              'end_ms': c['end_ms'],
            },
          )
          .toList();
      await _db.from('post_chapters').insert(data);
    }
  }

  /// Deletes old subtitles and inserts new ones for a given media_id.
  Future<void> saveSubtitles(
    String mediaId,
    List<Map<String, dynamic>> subtitles,
  ) async {
    await _db.from('post_subtitles').delete().eq('media_id', mediaId);
    if (subtitles.isNotEmpty) {
      final data = subtitles
          .map(
            (s) => {
              'media_id': mediaId,
              'language': s['language'] ?? 'en',
              'text': s['text'],
              'start_ms': s['start_ms'],
              'end_ms': s['end_ms'],
            },
          )
          .toList();
      await _db.from('post_subtitles').insert(data);
    }
  }

  Future<List<Map<String, dynamic>>> loadChapters(String mediaId) async {
    final rows = await _db
        .from('post_chapters')
        .select('label, start_ms, end_ms')
        .eq('media_id', mediaId)
        .order('start_ms');
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> loadSubtitles(String mediaId) async {
    final rows = await _db
        .from('post_subtitles')
        .select('language, text, start_ms, end_ms')
        .eq('media_id', mediaId)
        .order('start_ms');
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Chapters + captions for a video post, for the watch page. Null when the
  /// post has no video the viewer can see.
  Future<VideoExtras?> videoExtras(String postId) async {
    final res = await _db.rpc('video_extras', params: {'p_post_id': postId});
    if (res == null) return null;
    return VideoExtras.fromMap(Map<String, dynamic>.from(res as Map));
  }

  /// Updates the poster path in post_media.
  Future<void> updatePosterPath(String mediaId, String path) async {
    await _db
        .from('post_media')
        .update({'poster_path': path})
        .eq('id', mediaId);
  }

  Future<bool> toggleSubscription(String creatorId) async {
    final result = await _db.rpc(
      'toggle_video_subscription',
      params: {'p_creator_id': creatorId},
    );
    return result as bool;
  }

  Future<int> subscriberCount(String creatorId) async {
    final result = await _db.rpc(
      'channel_subscriber_count',
      params: {'p_creator_id': creatorId},
    );
    return (result as num).toInt();
  }

  Future<bool> isSubscribed(String creatorId) async {
    final result = await _db.rpc(
      'is_subscribed_to_channel',
      params: {'p_creator_id': creatorId},
    );
    return result as bool;
  }

  Future<List<FeedPost>> getUserVideoPosts(
    String authorId, {
    int limit = 30,
  }) async {
    final rows = await getUserVideos(authorId, limit: limit);
    final posts = <FeedPost>[];
    for (final row in rows) {
      final postId = row['post_id'] as String;
      final thread = await _db.rpc('post_thread', params: {'p_root': postId});
      final list = (thread as List)
          .map((e) => FeedPost.fromMap(e as Map<String, dynamic>))
          .toList();
      if (list.isNotEmpty) posts.add(list.first);
    }
    return posts;
  }
}

final creatorRepositoryProvider = Provider<CreatorRepository>((ref) {
  return CreatorRepository(ref.watch(supabaseProvider));
});

// New provider for user videos in profile context
final userVideosProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      authorId,
    ) async {
      return ref.watch(creatorRepositoryProvider).getUserVideos(authorId);
    });

final reachStatsProvider = FutureProvider<ReachStats>((ref) async {
  return ref.watch(creatorRepositoryProvider).stats();
});
