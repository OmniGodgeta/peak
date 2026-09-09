import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/community_repository.dart';
import 'community_screen.dart';
import 'create_community_screen.dart';

/// The Communities tab: the communities you're in, plus a directory to browse.
class CommunitiesScreen extends ConsumerStatefulWidget {
  const CommunitiesScreen({super.key});

  @override
  ConsumerState<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

class _CommunitiesScreenState extends ConsumerState<CommunitiesScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(String slug) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CommunityScreen(slug: slug)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = ref.watch(myCommunitiesProvider);
    final browse = ref.watch(communitiesBrowseProvider(_query));

    return Scaffold(
      appBar: AppBar(title: const Text('Communities')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final slug = await Navigator.of(context).push<String>(
            MaterialPageRoute(builder: (_) => const CreateCommunityScreen()),
          );
          if (slug != null && mounted) {
            ref.invalidate(myCommunitiesProvider);
            _open(slug);
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('Create'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myCommunitiesProvider);
          ref.invalidate(communitiesBrowseProvider(_query));
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            mine.maybeWhen(
              data: (list) => list.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text('Your communities'),
                        ),
                        for (final c in list)
                          ListTile(
                            leading: const Icon(Icons.groups),
                            title: Text(c.name),
                            subtitle: Text(
                              '${c.memberCount} member'
                              '${c.memberCount == 1 ? '' : 's'} · '
                              '${c.myRole}',
                            ),
                            onTap: () => _open(c.slug),
                          ),
                        const Divider(height: 24),
                      ],
                    ),
              orElse: () => const SizedBox.shrink(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Find a community',
                  isDense: true,
                ),
              ),
            ),
            browse.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) =>
                  Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
              data: (list) {
                if (list.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('Nothing here yet.')),
                  );
                }
                return Column(
                  children: [
                    for (final c in list) _BrowseTile(summary: c, onTap: _open),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _BrowseTile extends StatelessWidget {
  const _BrowseTile({required this.summary, required this.onTap});
  final CommunitySummary summary;
  final void Function(String slug) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Text(summary.name.characters.first.toUpperCase()),
      ),
      title: Row(
        children: [
          Flexible(child: Text(summary.name, overflow: TextOverflow.ellipsis)),
          if (summary.isNsfw) ...[
            const SizedBox(width: 6),
            const Chip(
              label: Text('18+'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
        ],
      ),
      subtitle: Text(
        summary.description.isEmpty
            ? '${summary.memberCount} members'
            : '${summary.memberCount} members · ${summary.description}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: summary.isMember ? const Icon(Icons.check, size: 18) : null,
      onTap: () => onTap(summary.slug),
    );
  }
}
