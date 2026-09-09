import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/story_repository.dart';

final _viewersProvider = FutureProvider.family<List<StoryViewerEntry>, String>((
  ref,
  storyId,
) async {
  return ref.watch(storyRepositoryProvider).viewers(storyId);
});

/// Who has seen one of your stories. Plain list, newest first — no "watched
/// twice", no ranking.
class StoryViewersSheet extends ConsumerWidget {
  const StoryViewersSheet({super.key, required this.storyId});
  final String storyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewers = ref.watch(_viewersProvider(storyId));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Viewers', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            viewers.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('$e'),
              data: (list) => Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final v in list)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: AvatarCircle(
                          name: v.name,
                          path: v.avatarPath,
                          radius: 18,
                        ),
                        title: Text(v.name),
                        subtitle: Text('@${v.handle}@${v.domain}'),
                        trailing: Text(
                          _ago(v.seenAt),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  return '${d.inHours}h';
}
