import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'feed_repository.dart';
import 'supabase_providers.dart';

/// A soft-deleted post sitting in the 30-day "recently deleted" bin.
class DeletedPost {
  const DeletedPost({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.deletedAt,
    required this.purgesAt,
    required this.isReply,
    required this.media,
  });

  final String id;
  final String body;
  final DateTime createdAt;
  final DateTime deletedAt;
  final DateTime purgesAt;
  final bool isReply;
  final List<PostMedia> media;

  factory DeletedPost.fromMap(Map<String, dynamic> m) => DeletedPost(
    id: m['id'] as String,
    body: (m['body'] as String?) ?? '',
    createdAt: DateTime.parse(m['created_at'] as String),
    deletedAt: DateTime.parse(m['deleted_at'] as String),
    purgesAt: DateTime.parse(m['purges_at'] as String),
    isReply: m['reply_to'] != null,
    media: [
      for (final e in (m['media'] as List? ?? const []))
        PostMedia.fromMap(e as Map<String, dynamic>),
    ],
  );
}

/// Result of an export run: a signed, short-lived link to the JSON archive.
class ExportArchive {
  const ExportArchive({
    required this.url,
    required this.filename,
    required this.bytes,
  });

  final String url;
  final String filename;
  final int bytes;
}

/// Real-delete + export — the Phase 3 data controls (PRODUCT.md §9.2).
class DataRepository {
  DataRepository(this._db);
  final SupabaseClient _db;

  /// Start the 30-day account-deletion grace period. The app locks to the
  /// closing screen until this is cancelled or the account is purged.
  Future<void> requestAccountDeletion() => _db.rpc('request_account_deletion');

  Future<void> cancelAccountDeletion() => _db.rpc('cancel_account_deletion');

  Future<void> deletePost(String postId) =>
      _db.rpc('delete_post', params: {'p_post_id': postId});

  Future<void> restorePost(String postId) =>
      _db.rpc('restore_post', params: {'p_post_id': postId});

  Future<List<DeletedPost>> deletedPosts() async {
    final rows = await _db.rpc('my_deleted_posts') as List;
    return [
      for (final r in rows) DeletedPost.fromMap(r as Map<String, dynamic>),
    ];
  }

  /// Builds the archive server-side, then signs a one-hour download link for it
  /// on this side (the SDK knows the caller-reachable host; the `exports` RLS
  /// policy lets the owner sign their own file).
  Future<ExportArchive> requestExport() async {
    final res = await _db.functions.invoke('export');
    if (res.status != 200) {
      final msg = res.data is Map ? res.data['error'] : res.data;
      throw Exception('Export failed: $msg');
    }
    final data = res.data as Map<String, dynamic>;
    final path = data['path'] as String;
    final url = await _db.storage.from('exports').createSignedUrl(path, 3600);
    return ExportArchive(
      url: url,
      filename: data['filename'] as String,
      bytes: (data['bytes'] as num).toInt(),
    );
  }
}

final dataRepositoryProvider = Provider<DataRepository>((ref) {
  return DataRepository(ref.watch(supabaseProvider));
});

final deletedPostsProvider = FutureProvider<List<DeletedPost>>((ref) async {
  return ref.watch(dataRepositoryProvider).deletedPosts();
});
