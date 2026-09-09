import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// One attachment on a post. `kind` is 'image' | 'video' | 'audio'; for Phase 1
/// only images (including animated GIFs) are produced.
class PostMedia {
  const PostMedia({
    required this.kind,
    required this.storagePath,
    required this.altText,
    required this.width,
    required this.height,
    required this.durationMs,
  });

  final String kind;
  final String storagePath;
  final String? altText;
  final int? width;
  final int? height;
  final int? durationMs;

  double? get aspectRatio => (width != null && height != null && height! > 0)
      ? width! / height!
      : null;

  factory PostMedia.fromMap(Map<String, dynamic> m) => PostMedia(
    kind: (m['kind'] as String?) ?? 'image',
    storagePath: m['storage_path'] as String,
    altText: m['alt_text'] as String?,
    width: (m['width'] as num?)?.toInt(),
    height: (m['height'] as num?)?.toInt(),
    durationMs: (m['duration_ms'] as num?)?.toInt(),
  );
}

/// A row from the feed / thread RPCs: a post plus its author's public identity,
/// media, and the viewer's own like/repost state.
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
    required this.authorAvatarPath,
    required this.reactionCount,
    required this.replyCount,
    required this.repostCount,
    required this.viewerReacted,
    required this.viewerReposted,
    required this.media,
    this.title,
    this.longForm = false,
    this.isPinned = false,
    this.communityLabel,
    this.communityLabelNote,
    this.replyTo,
    this.depth = 0,
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
  final String? authorAvatarPath;
  final int reactionCount;
  final int replyCount;
  final int repostCount;
  final bool viewerReacted;
  final bool viewerReposted;
  final List<PostMedia> media;

  /// Long-form article title + flag. When [longForm] is true the card shows a
  /// lede and opens a dedicated reading page instead of a thread.
  final String? title;
  final bool longForm;

  /// True when the author has pinned this post to their profile (only ever set
  /// by `posts_by`).
  final bool isPinned;

  /// A community moderator's label on this post ("off-topic", …) + an optional
  /// note. Only set by `community_feed`.
  final String? communityLabel;
  final String? communityLabelNote;

  final String? replyTo; // set in thread views
  final int depth; // set in thread views

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
    authorAvatarPath: m['author_avatar_path'] as String?,
    reactionCount: (m['reaction_count'] as int?) ?? 0,
    replyCount: (m['reply_count'] as int?) ?? 0,
    repostCount: (m['repost_count'] as int?) ?? 0,
    viewerReacted: (m['viewer_reacted'] as bool?) ?? false,
    viewerReposted: (m['viewer_reposted'] as bool?) ?? false,
    media: [
      for (final e in (m['media'] as List? ?? const []))
        PostMedia.fromMap(e as Map<String, dynamic>),
    ],
    title: m['title'] as String?,
    longForm: (m['long_form'] as bool?) ?? false,
    isPinned: (m['is_pinned'] as bool?) ?? false,
    communityLabel: m['label'] as String?,
    communityLabelNote: m['label_note'] as String?,
    replyTo: m['reply_to'] as String?,
    depth: (m['depth'] as num?)?.toInt() ?? 0,
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

  /// A post plus its reply tree (up to 4 levels), ordered by depth then time.
  Future<List<FeedPost>> thread(String rootId) async {
    final rows = await _db.rpc('post_thread', params: {'p_root': rootId});
    return (rows as List)
        .map((e) => FeedPost.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  /// Public URL for a `post-media` storage object.
  String mediaUrl(String storagePath) =>
      _db.storage.from('post-media').getPublicUrl(storagePath);
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

/// Bumped whenever something that changes the feed happens elsewhere in the app
/// (a new post, a follow/unfollow). Screens that can't easily reach the feed
/// call `ref.read(feedRevisionProvider.notifier).bump()`.
final feedRevisionProvider = NotifierProvider<FeedRevision, int>(
  FeedRevision.new,
);

class FeedRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final feedProvider = FutureProvider<List<FeedPost>>((ref) async {
  ref.watch(selectedFeedProvider);
  ref.watch(feedRevisionProvider);
  return ref.watch(feedRepositoryProvider).latest();
});
