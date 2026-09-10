import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// One mirror/news source and its state (staff view).
class IngestSource {
  const IngestSource({
    required this.source,
    required this.enabled,
    required this.lastRunAt,
    required this.lastOkAt,
    required this.addedLast,
    required this.note,
    required this.seenTotal,
    required this.liveTotal,
  });

  final String source;
  final bool enabled;
  final DateTime? lastRunAt;
  final DateTime? lastOkAt;
  final int addedLast;
  final String? note;
  final int seenTotal;
  final int liveTotal;

  factory IngestSource.fromMap(Map<String, dynamic> m) => IngestSource(
    source: m['source'] as String,
    enabled: (m['enabled'] as bool?) ?? true,
    lastRunAt: _dt(m['last_run_at']),
    lastOkAt: _dt(m['last_ok_at']),
    addedLast: (m['added_last'] as num?)?.toInt() ?? 0,
    note: m['note'] as String?,
    seenTotal: (m['seen_total'] as num?)?.toInt() ?? 0,
    liveTotal: (m['live_total'] as num?)?.toInt() ?? 0,
  );
}

/// One recently ingested item.
class IngestItem {
  const IngestItem({
    required this.source,
    required this.externalId,
    required this.title,
    required this.url,
    required this.seenAt,
    required this.postId,
    required this.postBody,
    required this.postDeleted,
    required this.communitySlug,
  });

  final String source;
  final String externalId;
  final String? title;
  final String? url;
  final DateTime seenAt;
  final String? postId;
  final String? postBody;
  final bool postDeleted;
  final String? communitySlug;

  factory IngestItem.fromMap(Map<String, dynamic> m) => IngestItem(
    source: m['source'] as String,
    externalId: m['external_id'] as String,
    title: m['title'] as String?,
    url: m['url'] as String?,
    seenAt: DateTime.parse(m['seen_at'] as String),
    postId: m['post_id'] as String?,
    postBody: m['post_body'] as String?,
    postDeleted: (m['post_deleted'] as bool?) ?? false,
    communitySlug: m['community_slug'] as String?,
  );
}

DateTime? _dt(Object? v) => v is String ? DateTime.tryParse(v) : null;

class IngestAdminRepository {
  IngestAdminRepository(this._db);
  final SupabaseClient _db;

  Future<List<IngestSource>> sources() async {
    final rows = await _db.rpc('ingest_admin_sources') as List;
    return [
      for (final r in rows) IngestSource.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<void> setEnabled(String source, bool enabled) => _db.rpc(
    'ingest_set_source_enabled',
    params: {'p_source': source, 'p_enabled': enabled},
  );

  Future<List<IngestItem>> recent({int limit = 60}) async {
    final rows =
        await _db.rpc('ingest_recent', params: {'p_limit': limit}) as List;
    return [
      for (final r in rows) IngestItem.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<void> hidePost(String postId, {String? reason}) => _db.rpc(
    'admin_remove_post',
    params: {'p_post_id': postId, 'p_reason': reason},
  );
}

final ingestAdminRepositoryProvider = Provider<IngestAdminRepository>((ref) {
  return IngestAdminRepository(ref.watch(supabaseProvider));
});

final ingestAdminRevisionProvider = NotifierProvider<IngestAdminRevision, int>(
  IngestAdminRevision.new,
);

class IngestAdminRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final ingestSourcesProvider = FutureProvider<List<IngestSource>>((ref) async {
  ref.watch(ingestAdminRevisionProvider);
  return ref.watch(ingestAdminRepositoryProvider).sources();
});

final ingestRecentProvider = FutureProvider<List<IngestItem>>((ref) async {
  ref.watch(ingestAdminRevisionProvider);
  return ref.watch(ingestAdminRepositoryProvider).recent();
});
