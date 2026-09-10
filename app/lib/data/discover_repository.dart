import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'community_repository.dart';
import 'feed_repository.dart';
import 'supabase_providers.dart';

/// A person the graph suggests you might know, with the reason.
class PymkPerson {
  const PymkPerson({
    required this.id,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.avatarPath,
    required this.reason,
  });

  final String id;
  final String handle;
  final String domain;
  final String displayName;
  final String? avatarPath;
  final String reason;

  String get name => displayName.isNotEmpty ? displayName : handle;
  String get fqHandle => '@$handle@$domain';

  factory PymkPerson.fromMap(Map<String, dynamic> m) => PymkPerson(
    id: m['id'] as String,
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    avatarPath: m['avatar_path'] as String?,
    reason: (m['reason'] as String?) ?? 'Suggested for you',
  );
}

class SuggestedCommunity {
  const SuggestedCommunity({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.memberCount,
    required this.matchReason,
  });

  final String id;
  final String slug;
  final String name;
  final String description;
  final int memberCount;
  final String matchReason;

  factory SuggestedCommunity.fromMap(Map<String, dynamic> m) =>
      SuggestedCommunity(
        id: m['id'] as String,
        slug: m['slug'] as String,
        name: m['name'] as String,
        description: (m['description'] as String?) ?? '',
        memberCount: (m['member_count'] as int?) ?? 0,
        matchReason: (m['match_reason'] as String?) ?? '',
      );
}

class DiscoverRepository {
  DiscoverRepository(this._db);
  final SupabaseClient _db;

  Future<List<String>> myInterests() async {
    final rows = await _db.rpc('my_interests') as List;
    return [for (final r in rows) (r as Map)['topic'] as String];
  }

  Future<void> setInterests(List<String> topics) =>
      _db.rpc('set_my_interests', params: {'p_topics': topics});

  Future<List<PymkPerson>> peopleYouMayKnow() async {
    final rows = await _db.rpc('people_you_may_know') as List;
    return [
      for (final r in rows) PymkPerson.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<SuggestedCommunity>> suggestedCommunities() async {
    final rows = await _db.rpc('suggested_communities') as List;
    return [
      for (final r in rows)
        SuggestedCommunity.fromMap(r as Map<String, dynamic>),
    ];
  }
}

final discoverRepositoryProvider = Provider<DiscoverRepository>((ref) {
  return DiscoverRepository(ref.watch(supabaseProvider));
});

final myInterestsProvider = FutureProvider<List<String>>((ref) async {
  return ref.watch(discoverRepositoryProvider).myInterests();
});

final pymkProvider = FutureProvider<List<PymkPerson>>((ref) async {
  return ref.watch(discoverRepositoryProvider).peopleYouMayKnow();
});

final suggestedCommunitiesProvider = FutureProvider<List<SuggestedCommunity>>((
  ref,
) async {
  return ref.watch(discoverRepositoryProvider).suggestedCommunities();
});

/// The most active public communities — shown on Discover so a brand-new
/// account (no follows yet) still has somewhere to go. Graph-independent.
final popularCommunitiesProvider = FutureProvider<List<CommunitySummary>>((
  ref,
) async {
  final all = await ref.watch(communityRepositoryProvider).browse((
    query: '',
    topic: null,
    sort: CommunitySort.active,
    includeNsfw: false,
  ));
  return all.take(10).toList();
});

/// A peek at what's being posted across the whole instance (the Local feed),
/// so Discover shows real content, not just suggestions. Graph-independent.
final freshOnPeakProvider = FutureProvider<List<FeedPost>>((ref) async {
  final posts = await ref.watch(feedRepositoryProvider).local(limit: 10);
  return posts;
});
