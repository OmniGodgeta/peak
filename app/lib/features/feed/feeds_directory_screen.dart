import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/custom_feed_repository.dart';
import '../../data/feed_repository.dart';

/// A directory of public custom feeds. Add one and it's copied into your own
/// feeds (yours to edit), and shows up in the Home feed switcher.
class FeedsDirectoryScreen extends ConsumerStatefulWidget {
  const FeedsDirectoryScreen({super.key});

  @override
  ConsumerState<FeedsDirectoryScreen> createState() =>
      _FeedsDirectoryScreenState();
}

class _FeedsDirectoryScreenState extends ConsumerState<FeedsDirectoryScreen> {
  String _query = '';
  String _sort = 'popular';

  Future<void> _add(BrowsedFeed f) async {
    try {
      await ref.read(customFeedRepositoryProvider).copy(f.id);
      ref.read(feedRevisionProvider.notifier).bump();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added “${f.name}” to your feeds')),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _addFromLink() async {
    final c = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a feed from a link'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Paste a peak.social/f/… link',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Find'),
          ),
        ],
      ),
    );
    if (raw == null) return;
    final id = feedIdFromShare(raw);
    if (id == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That doesn’t look like a feed link')),
        );
      }
      return;
    }
    final meta = await ref.read(customFeedMetaProvider(id).future);
    if (!mounted) return;
    if (meta == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That feed isn’t public or doesn’t exist'),
        ),
      );
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(meta.name),
        content: Text(
          'By @${meta.ownerHandle} · ${_describe(meta.rules)}\n\n'
          'Add a copy to your feeds?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (go == true) await _add(meta);
  }

  @override
  Widget build(BuildContext context) {
    final feeds = ref.watch(
      customFeedsBrowseProvider((query: _query, sort: _sort)),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Feed directory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Add from a link',
            onPressed: _addFromLink,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search feeds',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SegmentedButton<String>(
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: 'popular', label: Text('Popular')),
                  ButtonSegment(value: 'new', label: Text('New')),
                ],
                selected: {_sort},
                onSelectionChanged: (s) => setState(() => _sort = s.first),
              ),
            ),
          ),
          Expanded(
            child: feeds.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (list) {
                if (list.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No public feeds yet. Make one of yours public from '
                        'Custom feeds and it shows up here.',
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
                      subtitle: Text(
                        'by ${f.ownerName} · ${_describe(f.rules)}'
                        '${f.copyCount > 0 ? ' · ${f.copyCount} added' : ''}',
                      ),
                      isThreeLine: true,
                      trailing: f.mine
                          ? const Chip(label: Text('Yours'))
                          : f.added
                          ? const Icon(Icons.check, size: 20)
                          : FilledButton.tonal(
                              onPressed: () => _add(f),
                              child: const Text('Add'),
                            ),
                      onTap: () => _share(f),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _share(BrowsedFeed f) {
    Clipboard.setData(ClipboardData(text: feedShareLink(f.id)));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Share link copied')));
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
