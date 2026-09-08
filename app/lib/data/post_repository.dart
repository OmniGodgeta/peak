import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

enum PostVisibility { circles, public, followers }

class PostRepository {
  PostRepository(this._db);
  final SupabaseClient _db;

  /// Create a top-level post.
  ///
  /// Phase 1 writes directly (RLS + triggers enforce the invariants). Once the
  /// `publish` Edge Function is deployed this routes through it instead, so
  /// mention resolution and fan-out happen server-side.
  Future<void> createPost({
    required String body,
    required PostVisibility visibility,
    required List<String> circleIds,
    String? contentWarning,
    bool isSensitive = false,
  }) async {
    final uid = _db.auth.currentUser!.id;

    final persona = await _db
        .from('persona')
        .select('id')
        .eq('account_id', uid)
        .eq('is_default', true)
        .single();

    final post = await _db
        .from('post')
        .insert({
          'author_id': uid,
          'persona_id': persona['id'],
          'body': body,
          'visibility': visibility.name,
          'content_warning': contentWarning,
          'is_sensitive': isSensitive,
        })
        .select('id')
        .single();

    if (visibility == PostVisibility.circles && circleIds.isNotEmpty) {
      await _db.from('post_audience').insert([
        for (final cid in circleIds) {'post_id': post['id'], 'circle_id': cid},
      ]);
    }
  }
}

final postRepositoryProvider = Provider<PostRepository>((ref) {
  return PostRepository(ref.watch(supabaseProvider));
});
