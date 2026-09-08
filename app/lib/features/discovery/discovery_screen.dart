import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/people_repository.dart';
import '../profile/user_profile_screen.dart';

/// Phase 5 fills this with custom feeds, interests, events and a local tab.
/// For now it's people search — enough to build a follow graph.
class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.trim().length >= 2
        ? ref.watch(peopleSearchProvider(_query.trim()))
        : null;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            hintText: 'Search people',
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
      ),
      body: switch (results) {
        null => const _Hint(),
        _ => results.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (people) => people.isEmpty
              ? const Center(child: Text('No one found.'))
              : ListView.separated(
                  itemCount: people.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _PersonTile(person: people[i]),
                ),
        ),
      },
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
          'Find people by handle or name.\n'
          'Custom feeds, interests, local events and search come in Phase 5.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person});
  final PersonSummary person;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Text(
          person.name.characters.first.toUpperCase(),
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
      title: Row(
        children: [
          Flexible(child: Text(person.name, overflow: TextOverflow.ellipsis)),
          if (person.isTeen) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.shield_outlined,
              size: 13,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
      subtitle: Text(person.fqHandle, overflow: TextOverflow.ellipsis),
      trailing: person.isFollowing
          ? Chip(
              label: const Text('Following'),
              visualDensity: VisualDensity.compact,
            )
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UserProfileScreen(handle: person.handle),
        ),
      ),
    );
  }
}
