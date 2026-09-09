import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'feed_repository.dart';
import 'supabase_providers.dart';

enum CommunityJoinPolicy { open, request, invite }

CommunityJoinPolicy _policy(String? s) => switch (s) {
  'request' => CommunityJoinPolicy.request,
  'invite' => CommunityJoinPolicy.invite,
  _ => CommunityJoinPolicy.open,
};

/// Full community detail + the viewer's relationship to it (`community_view`).
class Community {
  const Community({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.topics,
    required this.joinPolicy,
    required this.isNsfw,
    required this.isListed,
    required this.memberCount,
    required this.pendingCount,
    required this.myRole,
    required this.myState,
  });

  final String id;
  final String slug;
  final String name;
  final String description;
  final List<String> topics;
  final CommunityJoinPolicy joinPolicy;
  final bool isNsfw;
  final bool isListed;
  final int memberCount;
  final int pendingCount; // pending join requests (0 unless you moderate)
  final String? myRole; // member | moderator | admin
  final String? myState; // active | request | banned

  bool get isMember => myState == 'active';
  bool get isPending => myState == 'request';
  bool get canModerate => myRole == 'moderator' || myRole == 'admin';
  bool get isAdmin => myRole == 'admin';

  factory Community.fromMap(Map<String, dynamic> m) => Community(
    id: m['id'] as String,
    slug: m['slug'] as String,
    name: m['name'] as String,
    description: (m['description'] as String?) ?? '',
    topics: [for (final t in (m['topics'] as List? ?? const [])) t as String],
    joinPolicy: _policy(m['join_policy'] as String?),
    isNsfw: (m['is_nsfw'] as bool?) ?? false,
    isListed: (m['is_listed'] as bool?) ?? true,
    memberCount: (m['member_count'] as int?) ?? 0,
    pendingCount: (m['pending_count'] as int?) ?? 0,
    myRole: m['my_role'] as String?,
    myState: m['my_state'] as String?,
  );
}

/// A member (or a pending requester, or a banned user) with their identity.
class CommunityPerson {
  const CommunityPerson({
    required this.memberId,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.avatarPath,
    this.role,
    this.flair,
    this.at,
  });

  final String memberId;
  final String handle;
  final String domain;
  final String displayName;
  final String? avatarPath;
  final String? role; // member | moderator | admin (roster only)
  final String? flair;
  final DateTime? at; // joined / requested time

  String get name => displayName.isNotEmpty ? displayName : handle;
  String get fqHandle => '@$handle@$domain';

  factory CommunityPerson.fromMap(Map<String, dynamic> m) => CommunityPerson(
    memberId: m['member_id'] as String,
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    avatarPath: m['avatar_path'] as String?,
    role: m['role'] as String?,
    flair: m['flair'] as String?,
    at: switch (m) {
      {'since': final String s} => DateTime.parse(s),
      {'requested_at': final String s} => DateTime.parse(s),
      _ => null,
    },
  );
}

enum CommunitySort { active, newest, largest }

extension CommunitySortRpc on CommunitySort {
  String get rpc => switch (this) {
    CommunitySort.active => 'active',
    CommunitySort.newest => 'new',
    CommunitySort.largest => 'large',
  };
}

/// Filters for the community directory.
typedef BrowseQuery = ({
  String query,
  String? topic,
  CommunitySort sort,
  bool includeNsfw,
});

/// A row from the directory (`communities_browse`).
class CommunitySummary {
  const CommunitySummary({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.topics,
    required this.isNsfw,
    required this.memberCount,
    required this.isMember,
    required this.lastActivityAt,
    required this.posts7d,
  });

  final String id;
  final String slug;
  final String name;
  final String description;
  final List<String> topics;
  final bool isNsfw;
  final int memberCount;
  final bool isMember;
  final DateTime? lastActivityAt;
  final int posts7d;

  factory CommunitySummary.fromMap(Map<String, dynamic> m) => CommunitySummary(
    id: m['id'] as String,
    slug: m['slug'] as String,
    name: m['name'] as String,
    description: (m['description'] as String?) ?? '',
    topics: [for (final t in (m['topics'] as List? ?? const [])) t as String],
    isNsfw: (m['is_nsfw'] as bool?) ?? false,
    memberCount: (m['member_count'] as int?) ?? 0,
    isMember: (m['is_member'] as bool?) ?? false,
    lastActivityAt: m['last_activity_at'] == null
        ? null
        : DateTime.parse(m['last_activity_at'] as String),
    posts7d: (m['posts_7d'] as int?) ?? 0,
  );
}

/// A topic tag with how many communities use it (`community_topics`).
typedef CommunityTopic = ({String topic, int count});

/// A row from `my_communities`.
class MyCommunity {
  const MyCommunity({
    required this.id,
    required this.slug,
    required this.name,
    required this.myRole,
    required this.memberCount,
  });

  final String id;
  final String slug;
  final String name;
  final String myRole;
  final int memberCount;

  factory MyCommunity.fromMap(Map<String, dynamic> m) => MyCommunity(
    id: m['id'] as String,
    slug: m['slug'] as String,
    name: m['name'] as String,
    myRole: (m['my_role'] as String?) ?? 'member',
    memberCount: (m['member_count'] as int?) ?? 0,
  );
}

/// One entry in a community's transparent moderation log.
class ModLogEntry {
  const ModLogEntry({
    required this.id,
    required this.action,
    required this.label,
    required this.reason,
    required this.createdAt,
    required this.actorName,
    required this.targetName,
    required this.targetPostId,
  });

  final String id;
  final String action;
  final String? label;
  final String? reason;
  final DateTime createdAt;
  final String? actorName;
  final String? targetName;
  final String? targetPostId;

  /// A plain-language summary, e.g. "Alice removed a post".
  String describe() {
    final actor = actorName ?? 'A moderator';
    final target = targetName ?? 'someone';
    return switch (action) {
      'approve_request' => '$actor approved $target',
      'decline_request' => '$actor declined $target',
      'set_role' => '$actor set $target to ${label ?? "a new role"}',
      'remove_member' => '$actor removed $target',
      'ban_member' => '$actor banned $target',
      'unban_member' => '$actor unbanned $target',
      'label_post' => '$actor labelled a post "${label ?? ""}"',
      'unlabel_post' => '$actor removed a label from a post',
      'remove_post' => '$actor removed a post',
      'edit_settings' => '$actor edited the community settings',
      _ => '$actor did $action',
    };
  }

  factory ModLogEntry.fromMap(Map<String, dynamic> m) => ModLogEntry(
    id: m['id'] as String,
    action: m['action'] as String,
    label: m['label'] as String?,
    reason: m['reason'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    actorName: (m['actor_display_name'] as String?)?.isNotEmpty == true
        ? m['actor_display_name'] as String
        : m['actor_handle'] as String?,
    targetName: (m['target_display_name'] as String?)?.isNotEmpty == true
        ? m['target_display_name'] as String
        : m['target_handle'] as String?,
    targetPostId: m['target_post_id'] as String?,
  );
}

class CommunityRule {
  const CommunityRule({required this.title, required this.body});
  final String title;
  final String body;

  factory CommunityRule.fromMap(Map<String, dynamic> m) => CommunityRule(
    title: m['title'] as String,
    body: (m['body'] as String?) ?? '',
  );
}

/// One text channel inside a community (`community_channels`).
class CommunityChannel {
  const CommunityChannel({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.modsOnly,
    required this.postCount,
  });

  final String id;
  final String slug;
  final String name;
  final String description;
  final bool modsOnly;
  final int postCount;

  bool get isGeneral => slug == 'general';

  factory CommunityChannel.fromMap(Map<String, dynamic> m) => CommunityChannel(
    id: m['id'] as String,
    slug: m['slug'] as String,
    name: m['name'] as String,
    description: (m['description'] as String?) ?? '',
    modsOnly: (m['post_policy'] as String?) == 'moderators',
    postCount: (m['post_count'] as int?) ?? 0,
  );
}

class CommunityRepository {
  CommunityRepository(this._db);
  final SupabaseClient _db;

  Future<String> create({
    required String slug,
    required String name,
    String description = '',
    List<String> topics = const [],
    CommunityJoinPolicy joinPolicy = CommunityJoinPolicy.open,
    bool nsfw = false,
  }) async {
    return await _db.rpc(
      'create_community',
      params: {
        'p_slug': slug,
        'p_name': name,
        'p_description': description,
        'p_topics': topics,
        'p_join_policy': joinPolicy.name,
        'p_nsfw': nsfw,
      },
    ) as String;
  }

  Future<Community?> view(String slug) async {
    final rows = await _db.rpc('community_view', params: {'p_slug': slug});
    final list = rows as List;
    return list.isEmpty
        ? null
        : Community.fromMap(list.first as Map<String, dynamic>);
  }

  Future<List<CommunitySummary>> browse(BrowseQuery q) async {
    final rows = await _db.rpc(
      'communities_browse',
      params: {
        'p_query': q.query,
        'p_topic': q.topic,
        'p_sort': q.sort.rpc,
        'p_include_nsfw': q.includeNsfw,
      },
    ) as List;
    return [
      for (final r in rows) CommunitySummary.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<CommunityTopic>> topics() async {
    final rows = await _db.rpc('community_topics') as List;
    return [
      for (final r in rows)
        (
          topic: (r as Map<String, dynamic>)['topic'] as String,
          count: (r['community_count'] as int?) ?? 0,
        ),
    ];
  }

  Future<List<MyCommunity>> mine() async {
    final rows = await _db.rpc('my_communities') as List;
    return [
      for (final r in rows) MyCommunity.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<String> join(String communityId) async {
    return await _db.rpc(
      'join_community',
      params: {'p_community_id': communityId},
    ) as String;
  }

  Future<void> leave(String communityId) =>
      _db.rpc('leave_community', params: {'p_community_id': communityId});

  Future<List<FeedPost>> feed(String communityId) async {
    final rows = await _db.rpc(
      'community_feed',
      params: {'p_community_id': communityId},
    );
    return [
      for (final r in (rows as List))
        FeedPost.fromMap(r as Map<String, dynamic>),
    ];
  }

  // ── channels (4-4a) ─────────────────────────────────────────────────────

  Future<List<CommunityChannel>> channels(String communityId) async {
    final rows = await _db.rpc(
      'community_channels',
      params: {'p_community_id': communityId},
    ) as List;
    return [
      for (final r in rows) CommunityChannel.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<FeedPost>> channelFeed(String channelId) async {
    final rows = await _db.rpc(
      'community_channel_feed',
      params: {'p_channel_id': channelId},
    ) as List;
    return [for (final r in rows) FeedPost.fromMap(r as Map<String, dynamic>)];
  }

  Future<String> createChannel(
    String communityId, {
    required String slug,
    required String name,
    String description = '',
    bool modsOnly = false,
  }) async {
    return await _db.rpc(
      'create_channel',
      params: {
        'p_community_id': communityId,
        'p_slug': slug,
        'p_name': name,
        'p_description': description,
        'p_mods_only': modsOnly,
      },
    ) as String;
  }

  Future<void> updateChannel(
    String channelId, {
    required String name,
    required String description,
    required bool modsOnly,
  }) => _db.rpc(
    'update_channel',
    params: {
      'p_channel_id': channelId,
      'p_name': name,
      'p_description': description,
      'p_mods_only': modsOnly,
    },
  );

  Future<void> deleteChannel(String channelId) =>
      _db.rpc('delete_channel', params: {'p_channel_id': channelId});

  Future<void> reorderChannels(String communityId, List<String> ids) => _db.rpc(
    'reorder_channels',
    params: {'p_community_id': communityId, 'p_ids': ids},
  );

  // ── moderation ──────────────────────────────────────────────────────────

  Future<List<CommunityPerson>> _people(String rpc, String communityId) async {
    final rows =
        await _db.rpc(rpc, params: {'p_community_id': communityId}) as List;
    return [
      for (final r in rows) CommunityPerson.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<CommunityPerson>> roster(String communityId) =>
      _people('community_roster', communityId);

  Future<List<CommunityPerson>> pendingRequests(String communityId) =>
      _people('community_pending_requests', communityId);

  Future<List<CommunityPerson>> banned(String communityId) =>
      _people('community_banned', communityId);

  Future<void> approve(String communityId, String memberId) => _db.rpc(
    'approve_request',
    params: {'p_community_id': communityId, 'p_member_id': memberId},
  );

  Future<void> decline(String communityId, String memberId, {String? reason}) =>
      _db.rpc(
        'decline_request',
        params: {
          'p_community_id': communityId,
          'p_member_id': memberId,
          'p_reason': ?reason,
        },
      );

  Future<void> setRole(String communityId, String memberId, String role) =>
      _db.rpc(
        'set_member_role',
        params: {
          'p_community_id': communityId,
          'p_member_id': memberId,
          'p_role': role,
        },
      );

  Future<void> remove(
    String communityId,
    String memberId, {
    bool ban = false,
    String? reason,
  }) => _db.rpc(
    'remove_member',
    params: {
      'p_community_id': communityId,
      'p_member_id': memberId,
      'p_ban': ban,
      'p_reason': ?reason,
    },
  );

  Future<void> unban(String communityId, String memberId) => _db.rpc(
    'unban_member',
    params: {'p_community_id': communityId, 'p_member_id': memberId},
  );

  // ── labels + mod log (4-2) ──────────────────────────────────────────────

  Future<void> labelPost(String postId, String label, {String? note}) =>
      _db.rpc(
        'label_post',
        params: {'p_post_id': postId, 'p_label': label, 'p_note': ?note},
      );

  Future<void> unlabelPost(String postId) =>
      _db.rpc('unlabel_post', params: {'p_post_id': postId});

  Future<void> removePost(String postId, {String? reason}) => _db.rpc(
    'moderate_remove_post',
    params: {'p_post_id': postId, 'p_reason': ?reason},
  );

  Future<List<CommunityRule>> rules(String communityId) async {
    final rows = await _db.rpc(
      'community_rules',
      params: {'p_community_id': communityId},
    ) as List;
    return [
      for (final r in rows) CommunityRule.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<void> setRules(String communityId, List<CommunityRule> rules) =>
      _db.rpc(
        'set_community_rules',
        params: {
          'p_community_id': communityId,
          'p_rules': [
            for (final r in rules)
              if (r.title.trim().isNotEmpty)
                {'title': r.title.trim(), 'body': r.body.trim()},
          ],
        },
      );

  Future<void> setMyFlair(String communityId, String flair) => _db.rpc(
    'set_my_flair',
    params: {'p_community_id': communityId, 'p_flair': flair},
  );

  Future<List<ModLogEntry>> modLog(String communityId) async {
    final rows = await _db.rpc(
      'community_mod_log',
      params: {'p_community_id': communityId},
    ) as List;
    return [
      for (final r in rows) ModLogEntry.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<void> saveSettings({
    required String communityId,
    required String name,
    required String description,
    required List<String> topics,
    required CommunityJoinPolicy joinPolicy,
    required bool nsfw,
    required bool listed,
  }) => _db.rpc(
    'set_community_settings',
    params: {
      'p_community_id': communityId,
      'p_name': name,
      'p_description': description,
      'p_topics': topics,
      'p_join_policy': joinPolicy.name,
      'p_nsfw': nsfw,
      'p_is_listed': listed,
    },
  );
}

final communityRepositoryProvider = Provider<CommunityRepository>((ref) {
  return CommunityRepository(ref.watch(supabaseProvider));
});

final myCommunitiesProvider = FutureProvider<List<MyCommunity>>((ref) async {
  return ref.watch(communityRepositoryProvider).mine();
});

final communitiesBrowseProvider =
    FutureProvider.family<List<CommunitySummary>, BrowseQuery>((ref, q) async {
      return ref.watch(communityRepositoryProvider).browse(q);
    });

final communityTopicsProvider = FutureProvider<List<CommunityTopic>>((
  ref,
) async {
  return ref.watch(communityRepositoryProvider).topics();
});

final communityViewProvider = FutureProvider.family<Community?, String>((
  ref,
  slug,
) async {
  return ref.watch(communityRepositoryProvider).view(slug);
});

final communityFeedProvider = FutureProvider.family<List<FeedPost>, String>((
  ref,
  communityId,
) async {
  return ref.watch(communityRepositoryProvider).feed(communityId);
});

final communityRosterProvider =
    FutureProvider.family<List<CommunityPerson>, String>((ref, id) async {
      return ref.watch(communityRepositoryProvider).roster(id);
    });

final communityPendingProvider =
    FutureProvider.family<List<CommunityPerson>, String>((ref, id) async {
      return ref.watch(communityRepositoryProvider).pendingRequests(id);
    });

final communityBannedProvider =
    FutureProvider.family<List<CommunityPerson>, String>((ref, id) async {
      return ref.watch(communityRepositoryProvider).banned(id);
    });

final communityModLogProvider =
    FutureProvider.family<List<ModLogEntry>, String>((ref, id) async {
      return ref.watch(communityRepositoryProvider).modLog(id);
    });

final communityRulesProvider =
    FutureProvider.family<List<CommunityRule>, String>((ref, id) async {
      return ref.watch(communityRepositoryProvider).rules(id);
    });

final communityChannelsProvider =
    FutureProvider.family<List<CommunityChannel>, String>((ref, id) async {
      return ref.watch(communityRepositoryProvider).channels(id);
    });

final communityChannelFeedProvider =
    FutureProvider.family<List<FeedPost>, String>((ref, channelId) async {
      return ref.watch(communityRepositoryProvider).channelFeed(channelId);
    });
