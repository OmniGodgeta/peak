import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/story_repository.dart';
import 'story_viewers_sheet.dart';

/// Full-screen story viewer. Swipe (or auto-advance) between people; tap the
/// left / right thirds to step within a person's stories. Hold to pause.
class StoryViewerScreen extends ConsumerStatefulWidget {
  const StoryViewerScreen({
    super.key,
    required this.entries,
    required this.initialIndex,
  });

  final List<StoryTrayEntry> entries;
  final int initialIndex;

  @override
  ConsumerState<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _authorIndex = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _nextAuthor() {
    if (_authorIndex >= widget.entries.length - 1) {
      Navigator.of(context).maybePop();
    } else {
      _pages.nextPage(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
  }

  void _prevAuthor() {
    if (_authorIndex <= 0) return;
    _pages.previousPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.entries.length,
        onPageChanged: (i) => setState(() => _authorIndex = i),
        itemBuilder: (context, i) => _AuthorStories(
          key: ValueKey(widget.entries[i].authorId),
          entry: widget.entries[i],
          isActive: i == _authorIndex,
          onNextAuthor: _nextAuthor,
          onPrevAuthor: _prevAuthor,
        ),
      ),
    );
  }
}

class _AuthorStories extends ConsumerStatefulWidget {
  const _AuthorStories({
    super.key,
    required this.entry,
    required this.isActive,
    required this.onNextAuthor,
    required this.onPrevAuthor,
  });

  final StoryTrayEntry entry;
  final bool isActive;
  final VoidCallback onNextAuthor;
  final VoidCallback onPrevAuthor;

  @override
  ConsumerState<_AuthorStories> createState() => _AuthorStoriesState();
}

class _AuthorStoriesState extends ConsumerState<_AuthorStories>
    with SingleTickerProviderStateMixin {
  static const _perStory = Duration(seconds: 5);

  late final AnimationController _progress =
      AnimationController(vsync: this, duration: _perStory)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) _advance();
        });

  int _i = 0;
  List<Story>? _stories;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AuthorStories old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      _restart();
    } else if (!widget.isActive && old.isActive) {
      _progress.stop();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await ref
        .read(storyRepositoryProvider)
        .byAuthor(widget.entry.authorId);
    if (!mounted) return;
    // Start at the first unseen story if there is one.
    final firstUnseen = list.indexWhere((s) => !s.seen);
    setState(() {
      _stories = list;
      _i = firstUnseen < 0 ? 0 : firstUnseen;
    });
    if (widget.isActive) _restart();
  }

  void _restart() {
    if (_stories == null || _stories!.isEmpty) return;
    _progress
      ..reset()
      ..forward();
    _markSeen();
  }

  void _markSeen() {
    final s = _stories?[_i];
    if (s != null && !widget.entry.isSelf) {
      ref.read(storyRepositoryProvider).markSeen(s.id);
    }
  }

  void _advance() {
    if (_stories == null) return;
    if (_i < _stories!.length - 1) {
      setState(() => _i++);
      _restart();
    } else {
      widget.onNextAuthor();
    }
  }

  void _back() {
    if (_i > 0) {
      setState(() => _i--);
      _restart();
    } else {
      widget.onPrevAuthor();
    }
  }

  void _setPaused(bool p) {
    if (p) {
      _progress.stop();
    } else if (widget.isActive) {
      _progress.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final stories = _stories;
    final repo = ref.read(storyRepositoryProvider);

    if (stories == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (stories.isEmpty) {
      return const Center(
        child: Text('No stories', style: TextStyle(color: Colors.white)),
      );
    }
    final story = stories[_i];

    return SafeArea(
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.network(
              repo.mediaUrl(story.mediaPath),
              fit: BoxFit.contain,
              loadingBuilder: (c, w, p) => p == null
                  ? w
                  : const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
              errorBuilder: (c, e, s) => const Center(
                child: Icon(Icons.broken_image, color: Colors.white54),
              ),
            ),
          ),

          // tap zones
          Positioned.fill(
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _back,
                    onLongPressStart: (_) => _setPaused(true),
                    onLongPressEnd: (_) => _setPaused(false),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _advance,
                    onLongPressStart: (_) => _setPaused(true),
                    onLongPressEnd: (_) => _setPaused(false),
                  ),
                ),
              ],
            ),
          ),

          // progress bars + header
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Column(
              children: [
                Row(
                  children: [
                    for (var s = 0; s < stories.length; s++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: AnimatedBuilder(
                            animation: _progress,
                            builder: (_, _) => LinearProgressIndicator(
                              value: s < _i
                                  ? 1
                                  : s == _i
                                  ? _progress.value
                                  : 0,
                              minHeight: 2.5,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation(
                                Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.entry.name} · ${_ago(story.createdAt)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // caption
          if (story.caption != null && story.caption!.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: widget.entry.isSelf ? 64 : 24,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  story.caption!,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),

          // own story: viewer count → sheet
          if (widget.entry.isSelf)
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: Text(
                    story.viewerCount == 0
                        ? 'No views yet'
                        : '${story.viewerCount} '
                              '${story.viewerCount == 1 ? "view" : "views"}',
                  ),
                  onPressed: story.viewerCount == 0
                      ? null
                      : () {
                          _setPaused(true);
                          showModalBottomSheet<void>(
                            context: context,
                            builder: (_) =>
                                StoryViewersSheet(storyId: story.id),
                          ).whenComplete(() => _setPaused(false));
                        },
                ),
              ),
            ),
        ],
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
