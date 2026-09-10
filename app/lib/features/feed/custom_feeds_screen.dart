import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/custom_feed_repository.dart';
import '../../data/feed_repository.dart';
import 'custom_feed_edit_screen.dart';
import 'feeds_directory_screen.dart';

/// Manage your custom feeds — rule sets that produce a home feed.
class CustomFeedsScreen extends ConsumerWidget {
  const CustomFeedsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feeds = ref.watch(myCustomFeedsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Custom feeds'),
        actions: [
          IconButton(
            icon: const Icon(Icons.explore_outlined),
            tooltip: 'Feed directory',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const FeedsDirectoryScreen(),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final made = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const CustomFeedEditScreen()),
          );
          if (made == true) ref.invalidate(myCustomFeedsProvider);
        },
        icon: const Icon(Icons.add),
        label: const Text('New feed'),
      ),
      body: feeds.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'A custom feed is a name plus a few rules — keywords to '
                  'include or exclude, communities, media only. It then shows '
                  'up in the feed switcher on Home.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final f = list[i];
              return ListTile(
                title: Text(f.name),
                subtitle: Text(_describe(f.rules)),
                trailing: Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (f.isPublic)
                      const Icon(Icons.public, size: 16)
                    else
                      const Icon(Icons.lock_outline, size: 16),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'edit') {
                          final saved = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                              builder: (_) => CustomFeedEditScreen(existing: f),
                            ),
                          );
                          if (saved == true) {
                            ref.invalidate(myCustomFeedsProvider);
                          }
                        } else if (v == 'share') {
                          Clipboard.setData(
                            ClipboardData(text: feedShareLink(f.id)),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Share link copied'),
                              ),
                            );
                          }
                        } else if (v == 'delete') {
                          await ref
                              .read(customFeedRepositoryProvider)
                              .delete(f.id);
                          if (ref.read(activeCustomFeedProvider) == f.id) {
                            ref
                                .read(activeCustomFeedProvider.notifier)
                                .set(null);
                          }
                          ref.invalidate(myCustomFeedsProvider);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        if (f.isPublic)
                          const PopupMenuItem(
                            value: 'share',
                            child: Text('Copy share link'),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
                onTap: () {
                  ref.read(activeCustomFeedProvider.notifier).set(f.id);
                  Navigator.of(context).pop();
                },
              );
            },
          );
        },
      ),
    );
  }
}

String _describe(FeedRules r) {
  final parts = <String>[
    if (r.communities.isNotEmpty) '${r.communities.length} communities',
    if (r.from.isNotEmpty) '${r.from.length} people',
    if (r.anyWords.isNotEmpty) 'has: ${r.anyWords.join(", ")}',
    if (r.notWords.isNotEmpty) 'not: ${r.notWords.join(", ")}',
    if (r.onlyMedia) 'media only',
  ];
  return parts.isEmpty ? 'People you follow' : parts.join(' · ');
}
