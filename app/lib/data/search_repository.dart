import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

enum SearchKind { post, person, community }

class SearchHit {
  const SearchHit({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.handle,
    required this.avatarPath,
  });

  final SearchKind kind;
  final String id;
  final String title;
  final String subtitle;
  final String? handle; // person handle, or community slug
  final String? avatarPath;

  factory SearchHit.fromMap(Map<String, dynamic> m) => SearchHit(
        kind: switch (m['kind'] as String?) {
          'person' => SearchKind.person,
          'community' => SearchKind.community,
          _ => SearchKind.post,
        },
        id: m['id'] as String,
        title: (m['title'] as String?) ?? '',
        subtitle: (m['subtitle'] as String?) ?? '',
        handle: m['handle'] as String?,
        avatarPath: m['avatar_path'] as String?,
      );
}

class SearchRepository {
  SearchRepository(this._db);
  final SupabaseClient _db;

  Future<List<SearchHit>> all(String query, {String? lang}) async {
    final params = {'p_query': query};
    if (lang != null) params['p_lang'] = lang;
    final rows = await _db.rpc('search_all', params: params) as List;
    return [for (final r in rows) SearchHit.fromMap(r as Map<String, dynamic>)];
  }

  Future<void> saveSearch(String query, SearchKind kind) async {
    await _db.rpc('save_search', params: {
      'p_query': query,
      'p_kind': kind.name,
    });
  }

  Future<List<Map<String, dynamic>>> getSavedSearches() async {
    return await _db.rpc('get_saved_searches') as List<Map<String, dynamic>>;
  }

  Future<void> deleteSavedSearch(String id) async {
    await _db.rpc('delete_saved_search', params: {'p_id': id});
  }
}

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(ref.watch(supabaseProvider));
});

final searchResultsProvider = FutureProvider.family<List<SearchHit>, ({String query, String? lang})>(
  (ref, arg) async {
    final q = arg.query.trim();
    if (q.length < 2) return const [];
    return ref.watch(searchRepositoryProvider).all(q, lang: arg.lang);
  },
);