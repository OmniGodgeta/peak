import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// A row from the `feed_latest` RPC: a post plus its author's public identity
/// and the viewer's own like/repost state.
class FeedPost {
  const FeedPost({
    required this.id,
    required this.body,
    required this.contentWarning,
    required this.isSensitive,
    required this.visibility,
    required this.createdAt,
    required this.editedAt,
    required this.authorId,
    required this.authorHandle,
    required this.authorDomain,
    required this.authorDisplayName,
    required this.authorIsTeen,
    required this.reactionCount,
    required this.replyCount,
    required this.repostCount,
    required this.viewerReacted,
    required this.viewerReposted,
  });

  final String id;
  final String body;
  final String? contentWarning;
  final bool isSensitive;
  final String visibility;
  final DateTime createdAt;
  final DateTime? editedAt;
  final String authorId;
  final String authorHandle;
  final String authorDomain;
  final String authorDisplayName;
  final bool authorIsTeen;
  final int reactionCount;
  final int replyCount;
  final int repostCount;
  final bool viewerReacted;
  final bool viewerReposted;

  String get authorName =>
      authorDisplayName.isNotEmpty ? authorDisplayName : authorHandle;
  String get authorFqHandle => '@$authorHandle@$authorDomain';

  factory FeedPost.fromMap(Map<String, dynamic> m) => FeedPost(
    id: m['id'] as String,
    body: (m['body'] as String?) ?? '',
    contentWarning: m['content_warning'] as String?,
    isSensitive: (m['is_sensitive'] as bool?) ?? false,
    visibility: (m['visibility'] as String?) ?? 'circles',
    createdAt: DateTime.parse(m['created_at'] as String),
    editedAt: m['edited_at'] == null
        ? null
        : DateTime.parse(m['edited_at'] as String),
    authorId: m['author_id'] as String,
    authorHandle: m['author_handle'] as String,
    authorDomain: (m['author_domain'] as String?) ?? 'peak.social',
    authorDisplayName: (m['author_display_name'] as String?) ?? '',
    authorIsTeen: (m['author_is_teen'] as bool?) ?? false,
    reactionCount: (m['reaction_count'] as int?) ?? 0,
    replyCount: (m['reply_count'] as int?) ?? 0,
    repostCount: (m['repost_count'] as int?) ?? 0,
    viewerReacted: (m['viewer_reacted'] as bool?) ?? false,
    viewerReposted: (m['viewer_reposted'] as bool?) ?? false,
  );
}

class FeedRepository {
  FeedRepository(this._db);
  final SupabaseClient _db;

  Future<List<FeedPost>> latest({int limit = 30}) async {
    final rows = await _db.rpc('feed_latest', params: {'p_limit': limit});
    return (rows as List)
        .map((e) => FeedPost.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> toggleReaction(String postId) async {
    return await _db.rpc('toggle_reaction', params: {'p_post_id': postId})
        as bool;
  }

  Future<bool> toggleRepost(String postId) async {
    return await _db.rpc('toggle_repost', params: {'p_post_id': postId})
        as bool;
  }
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(ref.watch(supabaseProvider));
});

/// Which named feed is selected. Only `latest` is wired for now; `friendsFirst`
/// reuses the same rows and reorders client-side (Phase 1).
enum FeedKind { latest, friendsFirst }

final selectedFeedProvider = NotifierProvider<SelectedFeed, FeedKind>(
  SelectedFeed.new,
);

class SelectedFeed extends Notifier<FeedKind> {
  @override
  FeedKind build() => FeedKind.latest;
  void set(FeedKind kind) => state = kind;
}

final feedProvider = FutureProvider<List<FeedPost>>((ref) async {
  ref.watch(selectedFeedProvider);
  return ref.watch(feedRepositoryProvider).latest();
});
