import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../data/supabase_providers.dart';
import '../compose/compose_screen.dart';

/// Named feeds live here. Phase 1 ships **Latest** (reverse-chronological) and
/// **Friends first**; custom feeds arrive in Phase 5. There is deliberately no
/// infinite autoplaying scroll — after a page you get a "You're caught up" card.
enum FeedKind { latest, friendsFirst }

final selectedFeedProvider = StateProvider<FeedKind>((_) => FeedKind.latest);

final feedProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(selectedFeedProvider);
  final db = ref.watch(supabaseProvider);
  final rows = await db.rpc('feed_latest', params: {'p_limit': 30});
  return (rows as List).cast<Map<String, dynamic>>();
});

class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedProvider);
    final kind = ref.watch(selectedFeedProvider);

    return Scaffold(
      appBar: AppBar(
        title: DropdownButtonHideUnderline(
          child: DropdownButton<FeedKind>(
            value: kind,
            onChanged: (v) => v == null
                ? null
                : ref.read(selectedFeedProvider.notifier).state = v,
            items: const [
              DropdownMenuItem(value: FeedKind.latest, child: Text('Latest')),
              DropdownMenuItem(
                value: FeedKind.friendsFirst,
                child: Text('Friends first'),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const ComposeScreen())),
        child: const Icon(Icons.edit),
      ),
      body: feed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(
          message: '$e',
          onRetry: () => ref.invalidate(feedProvider),
        ),
        data: (posts) {
          if (posts.isEmpty) return const _EmptyFeed();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(feedProvider),
            child: ListView.separated(
              itemCount: posts.length + 1,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == posts.length) return const _CaughtUp();
                return _PostTile(post: posts[i]);
              },
            ),
          );
        },
      ),
    );
  }
}

void _notImplemented(BuildContext context, String what) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('$what — not built yet')));
}

class _PostTile extends StatelessWidget {
  const _PostTile({required this.post});
  final Map<String, dynamic> post;

  @override
  Widget build(BuildContext context) {
    final body = (post['body'] as String?) ?? '';
    final cw = post['content_warning'] as String?;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cw != null && cw.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(cw),
            ),
          Text(body),
          const SizedBox(height: 8),
          Row(
            children: [
              _CountAction(icon: Icons.favorite_border, onTap: () {}),
              const SizedBox(width: 16),
              _CountAction(icon: Icons.mode_comment_outlined, onTap: () {}),
              const SizedBox(width: 16),
              _CountAction(icon: Icons.repeat, onTap: () {}),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.help_outline),
                tooltip: 'Why am I seeing this?',
                onPressed: () =>
                    _notImplemented(context, 'Why am I seeing this — Phase 5'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CountAction extends StatelessWidget {
  const _CountAction({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Counts are private by default (see docs/PRODUCT.md §2.6) — no numbers here.
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 20),
      ),
    );
  }
}

class _CaughtUp extends StatelessWidget {
  const _CaughtUp();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(
            Icons.check_circle_outline,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 8),
          const Text("You're caught up."),
          const SizedBox(height: 4),
          Text(
            'No infinite scroll here. Come back later, or check Discover.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your feed is empty.'),
            const SizedBox(height: 8),
            Text(
              'Follow some people, or post something to one of your circles.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
