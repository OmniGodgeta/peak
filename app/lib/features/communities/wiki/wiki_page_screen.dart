import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/community_repository.dart';
import '../../../data/wiki_repository.dart';
import '../../feed/article_screen.dart' show ArticleBody;
import 'wiki_edit_screen.dart';
import 'wiki_history_screen.dart';

/// One wiki page, rendered with the shared tiny-Markdown [ArticleBody].
class WikiPageScreen extends ConsumerWidget {
  const WikiPageScreen({
    super.key,
    required this.community,
    required this.slug,
  });
  final Community community;
  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (community.id, slug);
    final page = ref.watch(wikiPageProvider(key));

    void refresh() {
      ref.invalidate(wikiPageProvider(key));
      ref.invalidate(communityWikiPagesProvider(community.id));
    }

    final p = page.asData?.value;

    return Scaffold(
      appBar: AppBar(
        title: Text(p?.title ?? 'Wiki'),
        actions: [
          if (p != null)
            IconButton(
              tooltip: 'History',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WikiHistoryScreen(page: p),
                ),
              ),
            ),
          if (p != null && p.canEdit)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') {
                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) =>
                          WikiEditScreen(community: community, existing: p),
                    ),
                  );
                  if (saved == true) refresh();
                } else if (v == 'pin') {
                  await ref
                      .read(wikiRepositoryProvider)
                      .setPinned(p.id, !p.isPinned);
                  refresh();
                } else if (v == 'delete') {
                  await ref.read(wikiRepositoryProvider).delete(p.id);
                  if (context.mounted) Navigator.of(context).pop();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(
                  value: 'pin',
                  child: Text(p.isPinned ? 'Unpin' : 'Pin to front page'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
      body: page.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (p) {
          if (p == null) {
            return const Center(child: Text('This page does not exist.'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ArticleBody(text: p.body ?? ''),
              const SizedBox(height: 24),
              Text(
                'Last edited ${_ago(p.updatedAt)}'
                '${p.updatedByHandle != null ? ' by @${p.updatedByHandle}' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}
