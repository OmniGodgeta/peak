import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'media_service.dart';
import 'supabase_providers.dart';

enum PostVisibility { circles, public, mentioned, followers }

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
  final String mimeType; // image/jpeg, image/png, image/gif, image/webp
  final bool isVideo;
  String altText;
  int? width;
  int? height;
  int? durationMs;

  bool get isGif => mimeType == 'image/gif';
}

class PostRepository {
  PostRepository(this._db, this._media);
  final SupabaseClient _db;
  final MediaService _media;

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
      final up = await _media.uploadPostMedia(
        bytes: m.bytes,
        contentType: m.mimeType,
        isVideo: m.isVideo,
      );
      rows.add({
        'post_id': postId,
        'kind': m.isVideo ? 'video' : 'image',
        'storage_path': up.path,
        'poster_path': up.posterPath,
        'alt_text': m.altText.trim().isEmpty ? null : m.altText.trim(),
        'width': up.width ?? m.width,
        'height': up.height ?? m.height,
        'duration_ms': up.durationMs ?? m.durationMs,
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
    // New Phase 5 fields
    String? languageTag,
    bool isDraft = false,
    DateTime? scheduledAt,
    String? quoteId,
    Map<String, dynamic>? pollData, // {'question': string, 'options': List<string>},
  }) async {
    final uid = _db.auth.currentUser!.id;
    final personaId = await _defaultPersonaId(uid);

    final postInsert = {
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
      'language_tag': ?languageTag,
      'is_draft': isDraft,
      'scheduled_at': ?scheduledAt?.toIso8601String(),
      'quote_of': ?quoteId,
    };
    final post = await _db.from('post').insert(postInsert).select('id').single();
    final postId = post['id'] as String;

    // Handle Poll creation if present
    if (pollData != null && pollData['question'] != null) {
      final pollId = await _createPoll(pollData);
      await _db.from('post').update({'poll_id': pollId}).eq('id', postId);
    }

    if (visibility == PostVisibility.circles && circleIds.isNotEmpty) {
      await _db.from('post_audience').insert([
        for (final cid in circleIds) {'post_id': postId, 'circle_id': cid},
      ]);
    }
    await _attachMedia(postId, uid, media);
  }

  Future<String> _createPoll(Map<String, dynamic> data) async {
    final pollId = (await _db.from('poll').insert({
      'question': data['question'],
    }).select('id').single())['id'] as String;

    for (var optionText in (data['options'] as List<dynamic>)) {
      await _db.from('poll_option').insert({
        'poll_id': pollId,
        'text': optionText as String,
      });
    }
    return pollId;
  }

  /// Reply to a post. Replies inherit the parent's visibility and (for circles
  /// posts) its audience, so the thread stays consistent.
  Future<void> createReply({
    required String parentId,
    required String body,
    List<PendingMedia> media = const [],
    String? contentWarning,
    bool isSensitive = false,
    // New Phase 5 fields for replies
    String? languageTag,
    bool isDraft = false,
    DateTime? scheduledAt,
    Map<String, dynamic>? pollData,
  }) async {
    final uid = _db.auth.currentUser!.id;
    final personaId = await _defaultPersonaId(uid);

    final parent = await _db
        .from('post')
        .select('visibility, root_id, community_id')
        .eq('id', parentId)
        .single();
    final rootId = (parent['root_id'] as String?) ?? parentId;

    final replyInsert = {
      'author_id': uid,
      'persona_id': personaId,
      'body': body,
      'visibility': parent['visibility'],
      'reply_to': parentId,
      'root_id': rootId,
      'content_warning': contentWarning,
      'is_sensitive': isSensitive,
      'community_id': ?parent['community_id'],
      'language_tag': ?languageTag,
      'is_draft': isDraft,
      if (scheduledAt != null) 'scheduled_at': scheduledAt.toIso8601String(),
    };

    final reply = await _db.from('post').insert(replyInsert).select('id').single();
    final replyId = reply['id'] as String;

    // Handle Poll creation if present in reply
    if (pollData != null && pollData['question'] != null) {
      final pollId = await _createPoll(pollData);
      await _db.from('post').update({'poll_id': pollId}).eq('id', replyId);
    }

    await _attachMedia(replyId, uid, media);
  }

  /// Update an existing post and record history.
  Future<void> updatePost({
    required String postId,
    String? body,
    String? title,
    String? contentWarning,
    bool? isSensitive,
    bool? isDraft,
    DateTime? scheduledAt,
    String? languageTag,
  }) async {
    final current = await _db.from('post').select('body, title, content_warning, is_sensitive, is_draft, scheduled_at, language_tag').eq('id', postId).single();

    final updates = <String, dynamic>{};
    if (body != null && body != current['body']) updates['body'] = body;
    if (title != null && title != current['title']) updates['title'] = title;
    if (contentWarning != null && contentWarning != current['content_warning']) updates['content_warning'] = contentWarning;
    if (isSensitive != null && isSensitive != current['is_sensitive']) updates['is_sensitive'] = isSensitive;
    if (isDraft != null && isDraft != current['is_draft']) updates['is_draft'] = isDraft;
    if (scheduledAt != null && scheduledAt != current['scheduled_at']) updates['scheduled_at'] = scheduledAt.toIso8601String();
    if (languageTag != null && languageTag != current['language_tag']) updates['language_tag'] = languageTag;

    if (updates.isEmpty) return;

    await _db.from('post').update(updates).eq('id', postId);
  }
}

final postRepositoryProvider = Provider<PostRepository>((ref) {
  return PostRepository(
    ref.watch(supabaseProvider),
    ref.watch(mediaServiceProvider),
  );
});
