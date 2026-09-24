import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

class AppNotice {
  const AppNotice({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.read,
    required this.actorHandle,
    required this.actorName,
    this.postId,
  });

  final String id;
  final String kind;
  final DateTime createdAt;
  final bool read;
  final String actorHandle;
  final String actorName;
  final String? postId;

  String get line => switch (kind) {
    'like' => '$actorName liked your post',
    'reply' => '$actorName replied to you',
    'follow' => '$actorName followed you',
    _ => '$actorName · $kind',
  };

  factory AppNotice.fromMap(Map<String, dynamic> m) {
    final actor = m['actor'] as Map<String, dynamic>?;
    final handle = (actor?['handle'] as String?) ?? 'someone';
    final name = (actor?['display_name'] as String?) ?? '';
    return AppNotice(
      id: m['id'] as String,
      kind: m['kind'] as String,
      createdAt: DateTime.parse(m['created_at'] as String),
      read: m['read_at'] != null,
      actorHandle: handle,
      actorName: name.isEmpty ? '@$handle' : name,
      postId: m['post_id'] as String?,
    );
  }
}

class NotificationRepository {
  NotificationRepository(this._db);
  final SupabaseClient _db;

  Future<List<AppNotice>> list() async {
    final rows = await _db
        .from('user_notification')
        .select(
          'id, kind, created_at, read_at, post_id, actor:profile!user_notification_actor_id_fkey(handle, display_name)',
        )
        .order('created_at', ascending: false)
        .limit(40);
    return [
      for (final row in rows as List)
        AppNotice.fromMap(row as Map<String, dynamic>),
    ];
  }

  Future<int> unreadCount() async {
    final rows = await _db
        .from('user_notification')
        .select('id')
        .isFilter('read_at', null);
    return (rows as List).length;
  }

  Future<void> markAllRead() async {
    await _db
        .from('user_notification')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .isFilter('read_at', null);
  }
}

final notificationRepositoryProvider = Provider<NotificationRepository>((ref) {
  return NotificationRepository(ref.watch(supabaseProvider));
});

final noticesProvider = FutureProvider<List<AppNotice>>((ref) async {
  return ref.watch(notificationRepositoryProvider).list();
});

final unreadNoticesProvider = FutureProvider<int>((ref) async {
  return ref.watch(notificationRepositoryProvider).unreadCount();
});
