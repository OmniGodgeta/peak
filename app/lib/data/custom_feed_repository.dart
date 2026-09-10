import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'feed_repository.dart';
import 'supabase_providers.dart';

/// The rule set behind a custom feed. All lists optional; an empty rule set
/// means "people you follow" (so the word filters act on your own feed).
class FeedRules {
  const FeedRules({
    this.communities = const [],
    this.from = const [],
    this.anyWords = const [],
    this.notWords = const [],
    this.onlyMedia = false,
  });

  final List<String> communities; // community ids
  final List<String> from; // profile ids
  final List<String> anyWords;
  final List<String> notWords;
  final bool onlyMedia;

  bool get hasPositive =>
      communities.isNotEmpty || from.isNotEmpty || anyWords.isNotEmpty;

  Map<String, dynamic> toJson() => {
    if (communities.isNotEmpty) 'communities': communities,
    if (from.isNotEmpty) 'from': from,
    if (anyWords.isNotEmpty) 'any_words': anyWords,
    if (notWords.isNotEmpty) 'not_words': notWords,
    if (onlyMedia) 'only_media': true,
  };

  factory FeedRules.fromJson(Map<String, dynamic> m) => FeedRules(
    communities: [
      for (final e in (m['communities'] as List? ?? const [])) '$e',
    ],
    from: [for (final e in (m['from'] as List? ?? const [])) '$e'],
    anyWords: [for (final e in (m['any_words'] as List? ?? const [])) '$e'],
    notWords: [for (final e in (m['not_words'] as List? ?? const [])) '$e'],
    onlyMedia: (m['only_media'] as bool?) ?? false,
  );

  FeedRules copyWith({
    List<String>? communities,
    List<String>? from,
    List<String>? anyWords,
    List<String>? notWords,
    bool? onlyMedia,
  }) => FeedRules(
    communities: communities ?? this.communities,
    from: from ?? this.from,
    anyWords: anyWords ?? this.anyWords,
    notWords: notWords ?? this.notWords,
    onlyMedia: onlyMedia ?? this.onlyMedia,
  );
}

class CustomFeed {
  const CustomFeed({
    required this.id,
    required this.name,
    required this.rules,
    required this.isPublic,
    required this.ownerId,
  });

  final String id;
  final String name;
  final FeedRules rules;
  final bool isPublic;
  final String ownerId;

  factory CustomFeed.fromMap(Map<String, dynamic> m) => CustomFeed(
    id: m['id'] as String,
    name: m['name'] as String,
    rules: FeedRules.fromJson((m['rules'] as Map?)?.cast() ?? const {}),
    isPublic: (m['is_public'] as bool?) ?? false,
    ownerId: m['owner_id'] as String,
  );
}

/// A public custom feed in the directory (or behind a share link).
class BrowsedFeed {
  const BrowsedFeed({
    required this.id,
    required this.name,
    required this.rules,
    required this.ownerHandle,
    required this.ownerDisplayName,
    required this.copyCount,
    required this.mine,
    required this.added,
  });

  final String id;
  final String name;
  final FeedRules rules;
  final String ownerHandle;
  final String ownerDisplayName;
  final int copyCount;
  final bool mine;
  final bool added;

  String get ownerName =>
      ownerDisplayName.isNotEmpty ? ownerDisplayName : ownerHandle;

  factory BrowsedFeed.fromMap(Map<String, dynamic> m) => BrowsedFeed(
    id: m['id'] as String,
    name: m['name'] as String,
    rules: FeedRules.fromJson((m['rules'] as Map?)?.cast() ?? const {}),
    ownerHandle: (m['owner_handle'] as String?) ?? '',
    ownerDisplayName: (m['owner_display_name'] as String?) ?? '',
    copyCount: (m['copy_count'] as num?)?.toInt() ?? 0,
    mine: (m['mine'] as bool?) ?? false,
    added: (m['added'] as bool?) ?? false,
  );
}

/// The feed id embedded in a Peak share link (or a bare id).
String? feedIdFromShare(String raw) {
  final s = raw.trim();
  final m = RegExp(
    r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
  ).firstMatch(s);
  return m?.group(1);
}

String feedShareLink(String id) => 'https://peak.social/f/$id';

class CustomFeedRepository {
  CustomFeedRepository(this._db);
  final SupabaseClient _db;

  String get _uid => _db.auth.currentUser!.id;

  Future<List<CustomFeed>> mine() async {
    final rows = await _db
        .from('custom_feed')
        .select()
        .eq('owner_id', _uid)
        .order('name');
    return [for (final r in rows) CustomFeed.fromMap(r)];
  }

  Future<String> save({
    String? id,
    required String name,
    required FeedRules rules,
    required bool isPublic,
  }) async {
    final row = {
      'id': ?id,
      'owner_id': _uid,
      'name': name,
      'rules': rules.toJson(),
      'is_public': isPublic,
    };
    final saved = await _db
        .from('custom_feed')
        .upsert(row)
        .select('id')
        .single();
    return saved['id'] as String;
  }

  Future<void> delete(String id) =>
      _db.from('custom_feed').delete().eq('id', id);

  Future<String> copy(String id) async =>
      await _db.rpc('copy_custom_feed', params: {'p_feed_id': id}) as String;

  Future<List<BrowsedFeed>> browse({
    String query = '',
    String sort = 'popular',
  }) async {
    final rows = await _db.rpc(
      'custom_feeds_browse',
      params: {'p_query': query, 'p_sort': sort},
    ) as List;
    return [
      for (final r in rows) BrowsedFeed.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<BrowsedFeed?> meta(String id) async {
    final rows =
        await _db.rpc('custom_feed_meta', params: {'p_feed_id': id}) as List;
    if (rows.isEmpty) return null;
    return BrowsedFeed.fromMap(rows.first as Map<String, dynamic>);
  }

  Future<List<FeedPost>> posts(String id, {int limit = 30}) async {
    final rows = await _db.rpc(
      'feed_custom',
      params: {'p_feed_id': id, 'p_limit': limit},
    );
    return (rows as List)
        .map((e) => FeedPost.fromMap(e as Map<String, dynamic>))
        .toList();
  }
}

final customFeedRepositoryProvider = Provider<CustomFeedRepository>((ref) {
  return CustomFeedRepository(ref.watch(supabaseProvider));
});

final myCustomFeedsProvider = FutureProvider<List<CustomFeed>>((ref) async {
  ref.watch(feedRevisionProvider);
  return ref.watch(customFeedRepositoryProvider).mine();
});

final customFeedPostsProvider = FutureProvider.family<List<FeedPost>, String>((
  ref,
  id,
) async {
  ref.watch(feedRevisionProvider);
  return ref.watch(customFeedRepositoryProvider).posts(id);
});

/// (query, sort) → public feeds in the directory.
final customFeedsBrowseProvider =
    FutureProvider.family<List<BrowsedFeed>, ({String query, String sort})>((
      ref,
      arg,
    ) async {
      ref.watch(feedRevisionProvider);
      return ref
          .watch(customFeedRepositoryProvider)
          .browse(query: arg.query, sort: arg.sort);
    });

final customFeedMetaProvider = FutureProvider.family<BrowsedFeed?, String>((
  ref,
  id,
) async {
  ref.watch(feedRevisionProvider);
  return ref.watch(customFeedRepositoryProvider).meta(id);
});
