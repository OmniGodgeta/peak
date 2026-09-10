import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/discover_repository.dart';
import '../../data/people_repository.dart';
import '../../data/search_repository.dart';
import '../communities/community_screen.dart';
import '../feed/thread_screen.dart';
import '../profile/user_profile_screen.dart';

/// Discover: search (people / communities / posts) plus, when the box is empty,
/// interests, people you may know, and communities for you. A local tab is
/// still to come.
class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  final _controller = TextEditingController();
  String _query = '';
  SearchKind? _filter;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openHit(SearchHit hit) {
    final route = switch (hit.kind) {
      SearchKind.person => MaterialPageRoute<void>(
        builder: (_) => UserProfileScreen(handle: hit.handle ?? ''),
      ),
      SearchKind.community => MaterialPageRoute<void>(
        builder: (_) => CommunityScreen(slug: hit.handle ?? ''),
      ),
      SearchKind.post => MaterialPageRoute<void>(
        builder: (_) => ThreadScreen(rootId: hit.id),
      ),
    };
    Navigator.of(context).push(route);
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.trim().length >= 2
        ? ref.watch(searchResultsProvider(_query.trim()))
        : null;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            hintText: 'Search Peak',
            prefixIcon: const Icon(Icons.search),
            border: InputBorder.none,
            filled: false,
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
        ),
        bottom: results == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(44),
                child: SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final f in [
                        null,
                        SearchKind.person,
                        SearchKind.community,
                        SearchKind.post,
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: ChoiceChip(
                            label: Text(switch (f) {
                              null => 'All',
                              SearchKind.person => 'People',
                              SearchKind.community => 'Communities',
                              SearchKind.post => 'Posts',
                            }),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
      body: switch (results) {
        null => const _DiscoverLanding(),
        _ => results.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (hits) {
            final shown = _filter == null
                ? hits
                : hits.where((h) => h.kind == _filter).toList();
            if (shown.isEmpty) {
              return const Center(child: Text('Nothing found.'));
            }
            return ListView.separated(
              itemCount: shown.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _HitTile(hit: shown[i], onTap: _openHit),
            );
          },
        ),
      },
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.hit, required this.onTap});
  final SearchHit hit;
  final void Function(SearchHit) onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget leading = switch (hit.kind) {
      SearchKind.person => AvatarCircle(
        name: hit.title.isEmpty ? (hit.handle ?? '?') : hit.title,
        path: hit.avatarPath,
        radius: 18,
      ),
      SearchKind.community => CircleAvatar(
        radius: 18,
        backgroundColor: scheme.secondaryContainer,
        child: Text(
          (hit.title.isEmpty ? '?' : hit.title).characters.first.toUpperCase(),
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
      ),
      SearchKind.post => CircleAvatar(
        radius: 18,
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(Icons.forum_outlined, size: 18, color: scheme.onSurface),
      ),
    };

    return ListTile(
      leading: leading,
      title: Text(
        hit.title.isEmpty ? '(untitled)' : hit.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        hit.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => onTap(hit),
    );
  }
}

/// Shown when the search box is empty: interests, people you may know, and
/// communities that match your interests. All suggestions come from your own
/// graph — never contacts or tracking.
class _DiscoverLanding extends ConsumerWidget {
  const _DiscoverLanding();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pymk = ref.watch(pymkProvider);
    final comms = ref.watch(suggestedCommunitiesProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(pymkProvider);
        ref.invalidate(suggestedCommunitiesProvider);
        ref.invalidate(myInterestsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _InterestsEditor(),
          const Divider(height: 1),
          _Section('People you may know'),
          pymk.when(
            loading: () => const _Loading(),
            error: (e, _) => _Err('$e'),
            data: (list) => list.isEmpty
                ? const _Empty('Follow a few people to get suggestions.')
                : Column(
                    children: [for (final p in list) _PymkTile(person: p)],
                  ),
          ),
          const Divider(height: 1),
          _Section('Communities for you'),
          comms.when(
            loading: () => const _Loading(),
            error: (e, _) => _Err('$e'),
            data: (list) => list.isEmpty
                ? const _Empty(
                    'Add interests above to see matching communities.',
                  )
                : Column(
                    children: [
                      for (final c in list)
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            child: Text(c.name.characters.first.toUpperCase()),
                          ),
                          title: Text(c.name),
                          subtitle: Text(
                            '${c.memberCount} members · ${c.matchReason}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CommunityScreen(slug: c.slug),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _InterestsEditor extends ConsumerWidget {
  const _InterestsEditor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interests = ref.watch(myInterestsProvider).asData?.value ?? const [];

    Future<void> edit() async {
      final controller = TextEditingController(text: interests.join(', '));
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Your interests'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'space, photography, rust',
              helperText: 'Comma-separated. Used only for your suggestions.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (result == null) return;
      final topics = result
          .split(RegExp(r'[,\n]+'))
          .map((t) => t.trim().toLowerCase())
          .where((t) => t.isNotEmpty)
          .toList();
      await ref.read(discoverRepositoryProvider).setInterests(topics);
      ref.invalidate(myInterestsProvider);
      ref.invalidate(suggestedCommunitiesProvider);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: interests.isEmpty
                ? Text(
                    'No interests set',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final t in interests)
                        Chip(
                          label: Text('#$t'),
                          visualDensity: VisualDensity.compact,
                          side: BorderSide.none,
                        ),
                    ],
                  ),
          ),
          TextButton(onPressed: edit, child: const Text('Edit interests')),
        ],
      ),
    );
  }
}

class _PymkTile extends ConsumerStatefulWidget {
  const _PymkTile({required this.person});
  final PymkPerson person;

  @override
  ConsumerState<_PymkTile> createState() => _PymkTileState();
}

class _PymkTileState extends ConsumerState<_PymkTile> {
  bool _followed = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    return ListTile(
      leading: AvatarCircle(name: p.name, path: p.avatarPath, radius: 18),
      title: Text(p.name),
      subtitle: Text(p.reason, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _followed
          ? const Text('Following')
          : OutlinedButton(
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      try {
                        await ref.read(peopleRepositoryProvider).follow(p.id);
                        setState(() => _followed = true);
                      } on Exception catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('$e')));
                        }
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: const Text('Follow'),
            ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UserProfileScreen(handle: p.handle),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(20),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class _Err extends StatelessWidget {
  const _Err(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Text(text));
}
