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
}

final creatorRepositoryProvider = Provider<CreatorRepository>((ref) {
  return CreatorRepository(ref.watch(supabaseProvider));
});

final reachStatsProvider = FutureProvider<ReachStats>((ref) async {
  return ref.watch(creatorRepositoryProvider).stats();
});
