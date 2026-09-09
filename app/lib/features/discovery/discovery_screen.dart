import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/search_repository.dart';
import '../communities/community_screen.dart';
import '../feed/thread_screen.dart';
import '../profile/user_profile_screen.dart';

/// Search across people, communities and posts, in one ranked list.
/// (Custom feeds, interests and a local tab are still to come in Phase 5.)
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
        null => const _Hint(),
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

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Search people, communities and posts.\n'
          'Custom feeds, interests and a local tab are still to come.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
