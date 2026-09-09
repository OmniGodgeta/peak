import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/community_repository.dart';
import '../../../data/wiki_repository.dart';
import 'wiki_edit_screen.dart';
import 'wiki_page_screen.dart';

/// The list of a community's wiki pages, pinned first.
class CommunityWikiScreen extends ConsumerWidget {
  const CommunityWikiScreen({super.key, required this.community});
  final Community community;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = ref.watch(communityWikiPagesProvider(community.id));

    return Scaffold(
      appBar: AppBar(title: const Text('Wiki')),
      floatingActionButton: community.canModerate
          ? FloatingActionButton.extended(
              onPressed: () async {
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => WikiEditScreen(community: community),
                  ),
                );
                if (saved == true) {
                  ref.invalidate(communityWikiPagesProvider(community.id));
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('New page'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.invalidate(communityWikiPagesProvider(community.id)),
        child: pages.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No wiki pages yet.')),
                  ),
                ],
              );
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final p = list[i];
                return ListTile(
                  leading: Icon(
                    p.isPinned ? Icons.push_pin : Icons.article_outlined,
                    size: 20,
                  ),
                  title: Text(p.title),
                  subtitle: Text('c/${community.slug}/wiki/${p.slug}'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          WikiPageScreen(community: community, slug: p.slug),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
