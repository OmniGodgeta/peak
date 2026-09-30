import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// A note from another server: a reply to one of our posts, or a post by
/// someone you follow elsewhere. Always plain text — remote HTML is never
/// rendered.
class RemoteNote {
  const RemoteNote({
    required this.id,
    required this.uri,
    required this.url,
    required this.body,
    required this.contentWarning,
    required this.publishedAt,
    required this.actorHandle,
    required this.actorName,
    required this.actorIcon,
  });

  final String id;
  final String uri;
  final String? url;
  final String body;
  final String? contentWarning;
  final DateTime publishedAt;
  final String actorHandle;
  final String? actorName;
  final String? actorIcon;

  factory RemoteNote.fromMap(Map<String, dynamic> m) => RemoteNote(
    id: m['id'] as String,
    uri: m['uri'] as String,
    url: m['url'] as String?,
    body: m['body'] as String? ?? '',
    contentWarning: m['content_warning'] as String?,
    publishedAt: DateTime.parse(m['published_at'] as String),
    actorHandle: m['actor_handle'] as String? ?? '',
    actorName: m['actor_name'] as String?,
    actorIcon: m['actor_icon'] as String?,
  );
}

class FederationStatus {
  const FederationStatus({
    required this.instanceOn,
    required this.federated,
    required this.isTeen,
    required this.alsoKnownAs,
    required this.movedTo,
    required this.remoteFollowers,
    required this.remoteFollowing,
  });

  /// Whether this Peak server federates at all (operator switch).
  final bool instanceOn;
  final bool federated;
  final bool isTeen;
  final List<String> alsoKnownAs;
  final String? movedTo;
  final int remoteFollowers;
  final int remoteFollowing;

  factory FederationStatus.fromMap(Map<String, dynamic> m) => FederationStatus(
    instanceOn: m['enabled'] as bool? ?? false,
    federated: m['federated'] as bool? ?? false,
    isTeen: m['is_teen'] as bool? ?? false,
    alsoKnownAs: [for (final a in (m['also_known_as'] as List? ?? [])) '$a'],
    movedTo: m['moved_to'] as String?,
    remoteFollowers: (m['remote_followers'] as num?)?.toInt() ?? 0,
    remoteFollowing: (m['remote_following'] as num?)?.toInt() ?? 0,
  );
}

class RemoteAccount {
  const RemoteAccount({
    required this.id,
    required this.handle,
    required this.name,
    required this.icon,
    required this.accepted,
  });
  final String id;
  final String handle;
  final String? name;
  final String? icon;
  final bool accepted;
}

class BlockedServer {
  const BlockedServer(this.domain, this.reason);
  final String domain;
  final String? reason;
}

class FederationRepository {
  FederationRepository(this._db);
  final SupabaseClient _db;

  Future<FederationStatus?> status() async {
    final rows = await _db.rpc('my_federation') as List;
    if (rows.isEmpty) return null;
    return FederationStatus.fromMap(rows.first as Map<String, dynamic>);
  }

  Future<void> setFederated(bool on) =>
      _db.rpc('set_my_federation', params: {'p_federated': on});

  Future<void> setAliases(List<String> aliases) =>
      _db.rpc('set_my_federation', params: {'p_also_known_as': aliases});

  Future<List<RemoteNote>> replies(String postId) async {
    final rows =
        await _db.rpc('remote_replies', params: {'p_post': postId}) as List;
    return [
      for (final r in rows) RemoteNote.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<RemoteNote>> feed({DateTime? before}) async {
    final rows = await _db.rpc(
      'feed_fediverse',
      params: {
        if (before != null) 'p_before': before.toUtc().toIso8601String(),
      },
    ) as List;
    return [
      for (final r in rows) RemoteNote.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<RemoteAccount>> following() async {
    final rows =
        await _db
                .from('remote_following')
                .select(
                  'state, remote_actor:remote_actor_id '
                  '(id, domain, preferred_username, display_name, icon_url)',
                )
            as List;
    return [
      for (final r in rows)
        () {
          final a = (r as Map)['remote_actor'] as Map;
          return RemoteAccount(
            id: a['id'] as String,
            handle: '${a['preferred_username'] ?? ''}@${a['domain']}',
            name: a['display_name'] as String?,
            icon: a['icon_url'] as String?,
            accepted: r['state'] == 'accepted',
          );
        }(),
    ];
  }

  Future<Map<String, dynamic>> _api(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _db.functions.invoke('federation/api/$path', body: body);
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Looks up @user@server without following.
  Future<Map<String, dynamic>> resolve(String handle) =>
      _api('resolve', {'handle': handle});

  Future<void> follow(String handle) => _api('follow', {'handle': handle});

  Future<void> unfollow(String remoteActorId) =>
      _api('unfollow', {'actor_id': remoteActorId});

  /// Move this account to another server. The new account must list this
  /// one under "also known as" first; the server checks.
  Future<void> moveTo(String handle) => _api('move', {'handle': handle});

  Future<List<BlockedServer>> blocklist() async {
    final rows = await _db.rpc('federation_blocklist') as List;
    return [
      for (final r in rows)
        BlockedServer((r as Map)['domain'] as String, r['reason'] as String?),
    ];
  }

  Future<void> setBlocked(String domain, bool blocked, {String? reason}) =>
      _db.rpc(
        'set_instance_block',
        params: {'p_domain': domain, 'p_blocked': blocked, 'p_reason': reason},
      );
}

/// A readable error from a failed federation API call.
String federationError(Object e) {
  if (e is FunctionException) {
    final d = e.details;
    if (d is Map && d['error'] is String) return d['error'] as String;
    if (e.status == 404) return "This server isn't federating yet.";
  }
  return '$e';
}

final federationRepositoryProvider = Provider<FederationRepository>(
  (ref) => FederationRepository(ref.watch(supabaseProvider)),
);

final federationStatusProvider = FutureProvider<FederationStatus?>(
  (ref) => ref.watch(federationRepositoryProvider).status(),
);

final remoteRepliesProvider = FutureProvider.family<List<RemoteNote>, String>(
  (ref, postId) => ref.watch(federationRepositoryProvider).replies(postId),
);
