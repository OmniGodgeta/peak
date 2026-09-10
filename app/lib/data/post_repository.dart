import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'supabase_providers.dart';

enum PostVisibility { circles, public, followers }

/// A picked-but-not-yet-uploaded attachment held by the composer.
class PendingMedia {
  PendingMedia({
    required this.bytes,
    required this.mimeType,
    this.isVideo = false,
    this.altText = '',
    this.width,
    this.height,
    this.durationMs,
  });

  final Uint8List bytes;
  final String
  mimeType; // image/jpeg, image/png, image/gif, image/webp, video/mp4
  final bool isVideo;
  String altText;
  int? width;
  int? height;
  int? durationMs;

  bool get isGif => mimeType == 'image/gif';
  String get kind => isVideo ? 'video' : 'image';

  String get _ext => switch (mimeType) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/avif' => 'avif',
    'video/quicktime' => 'mov',
    'video/webm' => 'webm',
    'video/mp4' => 'mp4',
    _ => isVideo ? 'mp4' : 'jpg',
  };

  String storagePathFor(String userId) => '$userId/${const Uuid().v4()}.$_ext';
}

class PostRepository {
  PostRepository(this._db);
  final SupabaseClient _db;

  Future<String> _defaultPersonaId(String uid) async {
    final persona = await _db
        .from('persona')
        .select('id')
        .eq('account_id', uid)
        .eq('is_default', true)
        .single();
    return persona['id'] as String;
  }

  Future<void> _attachMedia(
    String postId,
    String uid,
    List<PendingMedia> media,
  ) async {
    if (media.isEmpty) return;
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      final path = m.storagePathFor(uid);
      await _db.storage
          .from('post-media')
          .uploadBinary(
            path,
            m.bytes,
            fileOptions: FileOptions(contentType: m.mimeType, upsert: false),
          );
      rows.add({
        'post_id': postId,
        'kind': m.kind,
        'storage_path': path,
        'alt_text': m.altText.trim().isEmpty ? null : m.altText.trim(),
        'width': m.width,
        'height': m.height,
        'duration_ms': m.durationMs,
        'sort_order': i,
      });
    }
    await _db.from('post_media').insert(rows);
  }

  /// Create a top-level post. Pass [title] + `longForm: true` for an article,
  /// or [communityId] to post into a community.
  Future<void> createPost({
    required String body,
    required PostVisibility visibility,
    required List<String> circleIds,
    List<PendingMedia> media = const [],
    String? contentWarning,
    bool isSensitive = false,
    String? title,
    bool longForm = false,
    String? communityId,
    String? channelId,
  }) async {
    final uid = _db.auth.currentUser!.id;
    final personaId = await _defaultPersonaId(uid);

    final post = await _db
        .from('post')
        .insert({
          'author_id': uid,
          'persona_id': personaId,
          'body': body,
          'visibility': visibility.name,
          'content_warning': contentWarning,
          'is_sensitive': isSensitive,
          'long_form': longForm,
          if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
          'community_id': ?communityId,
          'channel_id': ?channelId,
        })
        .select('id')
        .single();
    final postId = post['id'] as String;

    if (visibility == PostVisibility.circles && circleIds.isNotEmpty) {
      await _db.from('post_audience').insert([
        for (final cid in circleIds) {'post_id': postId, 'circle_id': cid},
      ]);
    }
    await _attachMedia(postId, uid, media);
  }

  /// Reply to a post. Replies inherit the parent's visibility and (for circles
  /// posts) its audience, so the thread stays consistent.
  Future<void> createReply({
    required String parentId,
    required String body,
    List<PendingMedia> media = const [],
    String? contentWarning,
    bool isSensitive = false,
  }) async {
    final uid = _db.auth.currentUser!.id;
    final personaId = await _defaultPersonaId(uid);

    final parent = await _db
        .from('post')
        .select('visibility, root_id, community_id')
        .eq('id', parentId)
        .single();
    final rootId = (parent['root_id'] as String?) ?? parentId;

    // The reply carries the root's visibility value (and community, if any);
    // `post_thread` gates the whole thread on the root, so a reply is seen
    // exactly when the root is.
    final reply = await _db
        .from('post')
        .insert({
          'author_id': uid,
          'persona_id': personaId,
          'body': body,
          'visibility': parent['visibility'],
          'reply_to': parentId,
          'root_id': rootId,
          'content_warning': contentWarning,
          'is_sensitive': isSensitive,
          'community_id': ?parent['community_id'],
        })
        .select('id')
        .single();
    await _attachMedia(reply['id'] as String, uid, media);
  }
}

final postRepositoryProvider = Provider<PostRepository>((ref) {
  return PostRepository(ref.watch(supabaseProvider));
});
