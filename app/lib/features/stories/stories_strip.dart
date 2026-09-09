import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/story_repository.dart';
import 'story_composer_screen.dart';
import 'story_viewer_screen.dart';

/// The row of story rings above the feed. "Your story" is always first.
class StoriesStrip extends ConsumerWidget {
  const StoriesStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tray = ref.watch(storyTrayProvider);

    return tray.when(
      loading: () => const SizedBox(height: 104),
      error: (_, _) => const SizedBox.shrink(),
      data: (entries) {
        final mine = entries.where((e) => e.isSelf).firstOrNull;
        final others = entries.where((e) => !e.isSelf).toList();

        return SizedBox(
          height: 104,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            children: [
              _YourStory(mine: mine, others: entries),
              for (final e in others)
                _StoryRing(entry: e, onTap: () => _open(context, entries, e)),
            ],
          ),
        );
      },
    );
  }

  void _open(
    BuildContext context,
    List<StoryTrayEntry> all,
    StoryTrayEntry tapped,
  ) {
    // Viewer walks everyone with stories, starting at the tapped person.
    final ordered = all.where((e) => e.storyCount > 0).toList();
    final start = ordered.indexWhere((e) => e.authorId == tapped.authorId);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StoryViewerScreen(
          entries: ordered,
          initialIndex: start < 0 ? 0 : start,
        ),
      ),
    );
  }
}

class _YourStory extends ConsumerWidget {
  const _YourStory({required this.mine, required this.others});
  final StoryTrayEntry? mine;
  final List<StoryTrayEntry> others;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return _Tile(
      label: 'Your story',
      onTap: () async {
        if (mine != null) {
          final ordered = others.where((e) => e.storyCount > 0).toList();
          final start = ordered.indexWhere((e) => e.authorId == mine!.authorId);
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => StoryViewerScreen(
                entries: ordered,
                initialIndex: start < 0 ? 0 : start,
              ),
            ),
          );
        } else {
          await _add(context, ref);
        }
      },
      onLongPress: mine == null ? null : () => _add(context, ref),
      child: Stack(
        children: [
          Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: mine == null
                  ? null
                  : Border.all(
                      color: mine!.hasUnseen
                          ? scheme.primary
                          : scheme.outlineVariant,
                      width: mine!.hasUnseen ? 2.5 : 1.5,
                    ),
            ),
            child: AvatarCircle(
              name: mine?.name ?? 'Y',
              path: mine?.avatarPath,
              radius: 28,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.add, size: 14, color: scheme.onPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const StoryComposerScreen()),
    );
    if (added == true) ref.invalidate(storyTrayProvider);
  }
}

class _StoryRing extends StatelessWidget {
  const _StoryRing({required this.entry, required this.onTap});
  final StoryTrayEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Tile(
      label: entry.name,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: entry.hasUnseen ? scheme.primary : scheme.outlineVariant,
            width: entry.hasUnseen ? 2.5 : 1.5,
          ),
        ),
        child: AvatarCircle(
          name: entry.name,
          path: entry.avatarPath,
          radius: 28,
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.onTap,
    required this.child,
    this.onLongPress,
  });
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: 72,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          children: [
            child,
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
