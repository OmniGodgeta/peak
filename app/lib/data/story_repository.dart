import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'supabase_providers.dart';

/// One person's stack of active stories, as shown in the feed strip.
class StoryTrayEntry {
  const StoryTrayEntry({
    required this.authorId,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.avatarPath,
    required this.isSelf,
    required this.storyCount,
    required this.hasUnseen,
  });

  final String authorId;
  final String handle;
  final String domain;
  final String displayName;
  final String? avatarPath;
  final bool isSelf;
  final int storyCount;
  final bool hasUnseen;

  String get name => displayName.isNotEmpty ? displayName : handle;

  factory StoryTrayEntry.fromMap(Map<String, dynamic> m) => StoryTrayEntry(
    authorId: m['author_id'] as String,
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    avatarPath: m['avatar_path'] as String?,
    isSelf: (m['is_self'] as bool?) ?? false,
    storyCount: (m['story_count'] as int?) ?? 0,
    hasUnseen: (m['has_unseen'] as bool?) ?? false,
  );
}

class Story {
  const Story({
    required this.id,
    required this.mediaPath,
    required this.mediaKind,
    required this.caption,
    required this.createdAt,
    required this.expiresAt,
    required this.seen,
    required this.viewerCount,
  });

  final String id;
  final String mediaPath;
  final String mediaKind;
  final String? caption;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool seen;
  final int viewerCount;

  factory Story.fromMap(Map<String, dynamic> m) => Story(
    id: m['id'] as String,
    mediaPath: m['media_path'] as String,
    mediaKind: (m['media_kind'] as String?) ?? 'image',
    caption: m['caption'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    expiresAt: DateTime.parse(m['expires_at'] as String),
    seen: (m['seen'] as bool?) ?? false,
    viewerCount: (m['viewer_count'] as int?) ?? 0,
  );
}

class StoryViewerEntry {
  const StoryViewerEntry({
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.avatarPath,
    required this.seenAt,
  });

  final String handle;
  final String domain;
  final String displayName;
  final String? avatarPath;
  final DateTime seenAt;

  String get name => displayName.isNotEmpty ? displayName : handle;

  factory StoryViewerEntry.fromMap(Map<String, dynamic> m) => StoryViewerEntry(
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    avatarPath: m['avatar_path'] as String?,
    seenAt: DateTime.parse(m['seen_at'] as String),
  );
}

class StoryRepository {
  StoryRepository(this._db);
  final SupabaseClient _db;

  String mediaUrl(String path) =>
      _db.storage.from('story-media').getPublicUrl(path);

  Future<String> uploadMedia(Uint8List bytes, String mime) async {
    final uid = _db.auth.currentUser!.id;
    final ext = switch (mime) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'jpg',
    };
    final path = '$uid/${const Uuid().v4()}.$ext';
    await _db.storage
        .from('story-media')
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));
    return path;
  }

  Future<void> post({
    required String mediaPath,
    String? caption,
    required List<String> circleIds,
  }) => _db.rpc(
    'post_story',
    params: {
      'p_media_path': mediaPath,
      'p_caption': caption,
      'p_circle_ids': circleIds,
    },
  );

  Future<List<StoryTrayEntry>> tray() async {
    final rows = await _db.rpc('stories_tray') as List;
    return [
      for (final r in rows) StoryTrayEntry.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<Story>> byAuthor(String authorId) async {
    final rows =
        await _db.rpc('story_thread', params: {'p_author': authorId}) as List;
    return [for (final r in rows) Story.fromMap(r as Map<String, dynamic>)];
  }

  Future<void> markSeen(String storyId) =>
      _db.rpc('mark_story_seen', params: {'p_story_id': storyId});

  Future<List<StoryViewerEntry>> viewers(String storyId) async {
    final rows =
        await _db.rpc('story_viewers', params: {'p_story_id': storyId}) as List;
    return [
      for (final r in rows) StoryViewerEntry.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<void> delete(String storyId) =>
      _db.rpc('delete_story', params: {'p_story_id': storyId});
}

final storyRepositoryProvider = Provider<StoryRepository>((ref) {
  return StoryRepository(ref.watch(supabaseProvider));
});

final storyTrayProvider = FutureProvider<List<StoryTrayEntry>>((ref) async {
  return ref.watch(storyRepositoryProvider).tray();
});

final storiesByAuthorProvider = FutureProvider.family<List<Story>, String>((
  ref,
  authorId,
) async {
  return ref.watch(storyRepositoryProvider).byAuthor(authorId);
});
