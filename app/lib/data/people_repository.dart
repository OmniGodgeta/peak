import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'feed_repository.dart';
import 'supabase_providers.dart';

/// A search hit / lightweight person reference.
class PersonSummary {
  const PersonSummary({
    required this.id,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.bio,
    required this.avatarPath,
    required this.isTeen,
    required this.isFollowing,
  });

  final String id;
  final String handle;
  final String domain;
  final String displayName;
  final String bio;
  final String? avatarPath;
  final bool isTeen;
  final bool isFollowing;

  String get name => displayName.isNotEmpty ? displayName : handle;
  String get fqHandle => '@$handle@$domain';

  factory PersonSummary.fromMap(Map<String, dynamic> m) => PersonSummary(
    id: m['id'] as String,
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    bio: (m['bio'] as String?) ?? '',
    avatarPath: m['avatar_path'] as String?,
    isTeen: (m['is_teen'] as bool?) ?? false,
    isFollowing: (m['is_following'] as bool?) ?? false,
  );
}

/// The full profile-page view: identity + the viewer's relationship + counts.
class ProfileView {
  const ProfileView({
    required this.id,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.bio,
    required this.pronouns,
    required this.avatarPath,
    required this.locationCoarse,
    required this.isTeen,
    required this.createdAt,
    required this.isSelf,
    required this.isFollowing,
    required this.followsYou,
    required this.showFollowCounts,
    required this.followerCount,
    required this.followingCount,
    required this.postCount,
    this.isVerifiedPerson = false,
    this.personhoodMethod,
    this.vouchCount = 0,
  });

  final String id;
  final String handle;
  final String domain;
  final String displayName;
  final String bio;
  final String? pronouns;
  final String? avatarPath;
  final String? locationCoarse;
  final bool isTeen;
  final DateTime createdAt;
  final bool isSelf;
  final bool isFollowing;
  final bool followsYou;
  final bool showFollowCounts;
  final int followerCount;
  final int followingCount;
  final int postCount;

  /// Proof-of-personhood: a real-person signal, not identity verification.
  /// [personhoodMethod] is 'staff' or 'vouch'.
  final bool isVerifiedPerson;
  final String? personhoodMethod;
  final int vouchCount;

  String get name => displayName.isNotEmpty ? displayName : handle;
  String get fqHandle => '@$handle@$domain';

  factory ProfileView.fromMap(Map<String, dynamic> m) => ProfileView(
    id: m['id'] as String,
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    bio: (m['bio'] as String?) ?? '',
    pronouns: m['pronouns'] as String?,
    avatarPath: m['avatar_path'] as String?,
    locationCoarse: m['location_coarse'] as String?,
    isTeen: (m['is_teen'] as bool?) ?? false,
    createdAt: DateTime.parse(m['created_at'] as String),
    isSelf: (m['is_self'] as bool?) ?? false,
    isFollowing: (m['is_following'] as bool?) ?? false,
    followsYou: (m['follows_you'] as bool?) ?? false,
    showFollowCounts: (m['show_follow_counts'] as bool?) ?? false,
    followerCount: (m['follower_count'] as int?) ?? 0,
    followingCount: (m['following_count'] as int?) ?? 0,
    postCount: (m['post_count'] as int?) ?? 0,
    isVerifiedPerson: (m['is_verified_person'] as bool?) ?? false,
    personhoodMethod: m['personhood_method'] as String?,
    vouchCount: (m['vouch_count'] as num?)?.toInt() ?? 0,
  );
}

class PeopleRepository {
  PeopleRepository(this._db);
  final SupabaseClient _db;

  Future<List<PersonSummary>> search(String query) async {
    if (query.trim().length < 2) return const [];
    final rows = await _db.rpc('search_people', params: {'q': query});
    return (rows as List)
        .map((e) => PersonSummary.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<ProfileView?> byHandle(
    String handle, {
    String domain = 'peak.social',
  }) async {
    final rows = await _db.rpc(
      'profile_view',
      params: {'p_handle': handle, 'p_domain': domain},
    );
    final list = (rows as List);
    return list.isEmpty
        ? null
        : ProfileView.fromMap(list.first as Map<String, dynamic>);
  }

  Future<List<FeedPost>> postsBy(String authorId) async {
    final rows = await _db.rpc('posts_by', params: {'p_author': authorId});
    return (rows as List)
        .map((e) => FeedPost.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> follow(String userId) async {
    await _db.from('follow').insert({
      'follower_id': _db.auth.currentUser!.id,
      'followee_id': userId,
    });
  }

  Future<void> unfollow(String userId) async {
    await _db
        .from('follow')
        .delete()
        .eq('follower_id', _db.auth.currentUser!.id)
        .eq('followee_id', userId);
  }
}

final peopleRepositoryProvider = Provider<PeopleRepository>((ref) {
  return PeopleRepository(ref.watch(supabaseProvider));
});

final peopleSearchProvider = FutureProvider.family<List<PersonSummary>, String>(
  (ref, query) async {
    return ref.watch(peopleRepositoryProvider).search(query);
  },
);

final profileViewProvider = FutureProvider.family<ProfileView?, String>((
  ref,
  handle,
) async {
  return ref.watch(peopleRepositoryProvider).byHandle(handle);
});

final postsByProvider = FutureProvider.family<List<FeedPost>, String>((
  ref,
  authorId,
) async {
  return ref.watch(peopleRepositoryProvider).postsBy(authorId);
});
