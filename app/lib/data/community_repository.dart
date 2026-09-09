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
    required this.memberCount,
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
  final int memberCount;
  final String? myRole; // member | moderator | admin
  final String? myState; // active | request | banned

  bool get isMember => myState == 'active';
  bool get isPending => myState == 'request';
  bool get canModerate => myRole == 'moderator' || myRole == 'admin';

  factory Community.fromMap(Map<String, dynamic> m) => Community(
    id: m['id'] as String,
    slug: m['slug'] as String,
    name: m['name'] as String,
    description: (m['description'] as String?) ?? '',
    topics: [for (final t in (m['topics'] as List? ?? const [])) t as String],
    joinPolicy: _policy(m['join_policy'] as String?),
    isNsfw: (m['is_nsfw'] as bool?) ?? false,
    memberCount: (m['member_count'] as int?) ?? 0,
    myRole: m['my_role'] as String?,
    myState: m['my_state'] as String?,
  );
}

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
  });

  final String id;
  final String slug;
  final String name;
  final String description;
  final List<String> topics;
  final bool isNsfw;
  final int memberCount;
  final bool isMember;

  factory CommunitySummary.fromMap(Map<String, dynamic> m) => CommunitySummary(
    id: m['id'] as String,
    slug: m['slug'] as String,
    name: m['name'] as String,
    description: (m['description'] as String?) ?? '',
    topics: [for (final t in (m['topics'] as List? ?? const [])) t as String],
    isNsfw: (m['is_nsfw'] as bool?) ?? false,
    memberCount: (m['member_count'] as int?) ?? 0,
    isMember: (m['is_member'] as bool?) ?? false,
  );
}

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

  Future<List<CommunitySummary>> browse(String query) async {
    final rows =
        await _db.rpc('communities_browse', params: {'p_query': query}) as List;
    return [
      for (final r in rows) CommunitySummary.fromMap(r as Map<String, dynamic>),
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
}

final communityRepositoryProvider = Provider<CommunityRepository>((ref) {
  return CommunityRepository(ref.watch(supabaseProvider));
});

final myCommunitiesProvider = FutureProvider<List<MyCommunity>>((ref) async {
  return ref.watch(communityRepositoryProvider).mine();
});

final communitiesBrowseProvider =
    FutureProvider.family<List<CommunitySummary>, String>((ref, query) async {
      return ref.watch(communityRepositoryProvider).browse(query);
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
