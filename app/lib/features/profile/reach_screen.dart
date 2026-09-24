import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/creator_repository.dart';

/// Opt-in counts for your own posts. No comparisons and no prompts to post.
class ReachScreen extends ConsumerWidget {
  const ReachScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(reachStatsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Your reach')),
      body: stats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (s) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Off until you turn it on. Then it counts your own posts, '
              'likes, replies, and reposts. It does not compare you with '
              'anyone, and it will not tell you to post more.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Count my posts'),
              value: s.optedIn,
              onChanged: (on) async {
                await ref.read(creatorRepositoryProvider).setOptIn(on);
                ref.invalidate(reachStatsProvider);
              },
            ),
            if (s.optedIn) ...[
              const SizedBox(height: 8),
              _Stat('Posts', s.posts),
              _Stat('Likes on your posts', s.likes),
              _Stat('Replies from other people', s.replies),
              _Stat('Reposts of your posts', s.reposts),
              _Stat('Discover boosts still running', s.activeBoosts),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final int? value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Text(
        '${value ?? 0}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}
