import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/labeler_repository.dart';
import 'labeler_edit_screen.dart';

/// Browse and manage labelers — user-run labelling services you can subscribe
/// to. Their labels then show on posts in your feed. Nothing here removes
/// content; labels are additive and always attributed.
class LabelersScreen extends ConsumerStatefulWidget {
  const LabelersScreen({super.key});

  @override
  ConsumerState<LabelersScreen> createState() => _LabelersScreenState();
}

class _LabelersScreenState extends ConsumerState<LabelersScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final mine = ref.watch(myLabelersProvider);
    final browse = ref.watch(labelersBrowseProvider(_query));
    final repo = ref.read(labelerRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Labelers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final made = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const LabelerEditScreen()),
          );
          if (made == true) ref.read(labelerRevisionProvider.notifier).bump();
        },
        icon: const Icon(Icons.add),
        label: const Text('New labeler'),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Subscribe to labelers you trust. Their labels appear on posts — '
              '“hide” labels blur a post until you tap it. You stay in control; '
              'unsubscribe any time.',
            ),
          ),
          _sectionHeader(context, 'Yours & subscribed'),
          mine.when(
            loading: () => const _LoadingRow(),
            error: (e, _) => _ErrorRow('$e'),
            data: (list) {
              if (list.isEmpty) {
                return const _EmptyRow('You have no labelers yet.');
              }
              return Column(
                children: [
                  for (final l in list)
                    ListTile(
                      leading: Icon(l.owned ? Icons.edit_note : Icons.rss_feed),
                      title: Text(l.name),
                      subtitle: Text(
                        [
                          if (l.owned) 'yours' else 'subscribed',
                          '${l.labelCount} labels',
                          '${l.appliedCount} applied',
                        ].join(' · '),
                      ),
                      trailing: l.owned
                          ? const Icon(Icons.chevron_right)
                          : TextButton(
                              onPressed: () async {
                                await repo.unsubscribe(l.id);
                                ref
                                    .read(labelerRevisionProvider.notifier)
                                    .bump();
                              },
                              child: const Text('Unsubscribe'),
                            ),
                      onTap: l.owned
                          ? () async {
                              final saved = await Navigator.of(context)
                                  .push<bool>(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          LabelerEditScreen(existing: l),
                                    ),
                                  );
                              if (saved == true) {
                                ref
                                    .read(labelerRevisionProvider.notifier)
                                    .bump();
                              }
                            }
                          : null,
                    ),
                ],
              );
            },
          ),
          _sectionHeader(context, 'Discover'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search labelers',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          browse.when(
            loading: () => const _LoadingRow(),
            error: (e, _) => _ErrorRow('$e'),
            data: (list) {
              if (list.isEmpty) {
                return const _EmptyRow('No public labelers match.');
              }
              return Column(
                children: [
                  for (final l in list)
                    ListTile(
                      leading: const Icon(Icons.shield_outlined),
                      title: Text(l.name),
                      subtitle: Text(
                        l.description.isEmpty
                            ? '@${l.ownerHandle} · ${l.subscriberCount} subscribers'
                            : '${l.description}\n@${l.ownerHandle} · '
                                  '${l.subscriberCount} subscribers',
                      ),
                      isThreeLine: l.description.isNotEmpty,
                      trailing: l.subscribed
                          ? TextButton(
                              onPressed: () async {
                                await repo.unsubscribe(l.id);
                                ref
                                    .read(labelerRevisionProvider.notifier)
                                    .bump();
                              },
                              child: const Text('Subscribed'),
                            )
                          : FilledButton.tonal(
                              onPressed: () async {
                                await repo.subscribe(l.id);
                                ref
                                    .read(labelerRevisionProvider.notifier)
                                    .bump();
                              },
                              child: const Text('Subscribe'),
                            ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

Widget _sectionHeader(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
  child: Text(
    text.toUpperCase(),
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      letterSpacing: 0.6,
    ),
  ),
);

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow(this.message);
  final String message;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Text(message));
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}
