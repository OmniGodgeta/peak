import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// A community wiki page (list row from `community_wiki_pages`, full row from
/// `wiki_page` which also carries [body]).
class WikiPage {
  const WikiPage({
    required this.id,
    required this.slug,
    required this.title,
    required this.isPinned,
    required this.updatedAt,
    required this.updatedByHandle,
    required this.canEdit,
    this.body,
  });

  final String id;
  final String slug;
  final String title;
  final bool isPinned;
  final DateTime updatedAt;
  final String? updatedByHandle;
  final bool canEdit;
  final String? body; // only from wiki_page()

  factory WikiPage.fromMap(Map<String, dynamic> m) => WikiPage(
    id: m['id'] as String,
    slug: m['slug'] as String,
    title: m['title'] as String,
    isPinned: (m['is_pinned'] as bool?) ?? false,
    updatedAt: DateTime.parse(m['updated_at'] as String),
    updatedByHandle: m['updated_by_handle'] as String?,
    canEdit: (m['can_edit'] as bool?) ?? false,
    body: m['body'] as String?,
  );
}

class WikiRevision {
  const WikiRevision({
    required this.id,
    required this.title,
    required this.note,
    required this.editedAt,
    required this.editorName,
    required this.body,
  });

  final String id;
  final String title;
  final String? note;
  final DateTime editedAt;
  final String? editorName;
  final String body;

  factory WikiRevision.fromMap(Map<String, dynamic> m) => WikiRevision(
    id: m['id'] as String,
    title: m['title'] as String,
    note: m['note'] as String?,
    editedAt: DateTime.parse(m['edited_at'] as String),
    editorName: (m['editor_display_name'] as String?)?.isNotEmpty == true
        ? m['editor_display_name'] as String
        : m['editor_handle'] as String?,
    body: m['body'] as String,
  );
}

class WikiRepository {
  WikiRepository(this._db);
  final SupabaseClient _db;

  Future<List<WikiPage>> pages(String communityId) async {
    final rows = await _db.rpc(
      'community_wiki_pages',
      params: {'p_community_id': communityId},
    ) as List;
    return [for (final r in rows) WikiPage.fromMap(r as Map<String, dynamic>)];
  }

  Future<WikiPage?> page(String communityId, String slug) async {
    final rows = await _db.rpc(
      'wiki_page',
      params: {'p_community_id': communityId, 'p_slug': slug},
    ) as List;
    return rows.isEmpty
        ? null
        : WikiPage.fromMap(rows.first as Map<String, dynamic>);
  }

  Future<List<WikiRevision>> history(String pageId) async {
    final rows = await _db.rpc(
      'wiki_page_history',
      params: {'p_page_id': pageId},
    ) as List;
    return [
      for (final r in rows) WikiRevision.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<String> save({
    required String communityId,
    required String slug,
    required String title,
    required String body,
    String? note,
  }) async {
    return await _db.rpc(
      'save_wiki_page',
      params: {
        'p_community_id': communityId,
        'p_slug': slug,
        'p_title': title,
        'p_body': body,
        'p_note': note,
      },
    ) as String;
  }

  Future<void> delete(String pageId) =>
      _db.rpc('delete_wiki_page', params: {'p_page_id': pageId});

  Future<void> setPinned(String pageId, bool pinned) => _db.rpc(
    'set_wiki_pinned',
    params: {'p_page_id': pageId, 'p_pinned': pinned},
  );
}

final wikiRepositoryProvider = Provider<WikiRepository>((ref) {
  return WikiRepository(ref.watch(supabaseProvider));
});

final communityWikiPagesProvider =
    FutureProvider.family<List<WikiPage>, String>((ref, communityId) async {
      return ref.watch(wikiRepositoryProvider).pages(communityId);
    });

final wikiPageProvider = FutureProvider.family<WikiPage?, (String, String)>((
  ref,
  key,
) async {
  return ref.watch(wikiRepositoryProvider).page(key.$1, key.$2);
});

final wikiHistoryProvider = FutureProvider.family<List<WikiRevision>, String>((
  ref,
  pageId,
) async {
  return ref.watch(wikiRepositoryProvider).history(pageId);
});
