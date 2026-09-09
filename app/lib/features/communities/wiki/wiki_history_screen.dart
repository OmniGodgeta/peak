import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/wiki_repository.dart';
import '../../feed/article_screen.dart' show ArticleBody;

/// The revision list for one wiki page; tap a revision to read it.
class WikiHistoryScreen extends ConsumerWidget {
  const WikiHistoryScreen({super.key, required this.page});
  final WikiPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(wikiHistoryProvider(page.id));

    return Scaffold(
      appBar: AppBar(title: Text('History · ${page.title}')),
      body: history.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (revisions) {
          if (revisions.isEmpty) {
            return const Center(child: Text('No revisions.'));
          }
          return ListView.separated(
            itemCount: revisions.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = revisions[i];
              return ListTile(
                title: Text(r.note?.isNotEmpty == true ? r.note! : r.title),
                subtitle: Text(
                  '${_stamp(r.editedAt)}'
                  '${r.editorName != null ? ' · ${r.editorName}' : ''}'
                  '${i == 0 ? ' · current' : ''}',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(r.title)),
                      body: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [ArticleBody(text: r.body)],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

String _stamp(DateTime t) {
  final l = t.toLocal();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)}';
}
