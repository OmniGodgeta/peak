import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feed_repository.dart';
import '../../app/avatar.dart';
import '../compose/compose_screen.dart';
import '../profile/user_profile_screen.dart';
import 'post_media_view.dart';
import 'thread_screen.dart';

/// A single post in the feed. Counts stay hidden by default (docs/PRODUCT.md
/// §2.6) for likes/reposts; reply count is shown because it's conversational
/// context, not a vanity metric.
class PostCard extends ConsumerStatefulWidget {
  const PostCard({super.key, required this.post, this.tappable = true});
  final FeedPost post;

  /// In a thread the current post shouldn't re-open the thread on tap.
  final bool tappable;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  late bool _reacted = widget.post.viewerReacted;
  late bool _reposted = widget.post.viewerReposted;
  late int _replyCount = widget.post.replyCount;
  bool _cwRevealed = false;

  void _openProfile(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UserProfileScreen(handle: widget.post.authorHandle),
      ),
    );
  }

  void _openThread() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ThreadScreen(rootId: widget.post.replyTo ?? widget.post.id),
      ),
    );
  }

  Future<void> _reply() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ComposeScreen(replyTo: widget.post)),
    );
    if (posted == true && mounted) setState(() => _replyCount++);
  }

  Future<void> _toggleReaction() async {
    setState(() => _reacted = !_reacted);
    try {
      final now = await ref
          .read(feedRepositoryProvider)
          .toggleReaction(widget.post.id);
      if (mounted) setState(() => _reacted = now);
    } on Exception {
      if (mounted) setState(() => _reacted = !_reacted); // revert
    }
  }

  Future<void> _toggleRepost() async {
    setState(() => _reposted = !_reposted);
    try {
      final now = await ref
          .read(feedRepositoryProvider)
          .toggleRepost(widget.post.id);
      if (mounted) setState(() => _reposted = now);
    } on Exception {
      if (mounted) setState(() => _reposted = !_reposted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cw = p.contentWarning;
    final hasCw = cw != null && cw.isNotEmpty;

    return InkWell(
      onTap: widget.tappable ? _openThread : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => _openProfile(context),
                  child: AvatarCircle(
                    name: p.authorName,
                    path: p.authorAvatarPath,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                p.authorName,
                                style: theme.textTheme.titleSmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (p.authorIsTeen) ...[
                              const SizedBox(width: 4),
                              Icon(
                                Icons.shield_outlined,
                                size: 13,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ],
                        ),
                        Text(
                          '${p.authorFqHandle} · ${_relativeTime(p.createdAt)}'
                          '${p.editedAt != null ? ' · edited' : ''}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
                _VisibilityChip(visibility: p.visibility),
              ],
            ),
            const SizedBox(height: 8),
            if (hasCw && !_cwRevealed)
              OutlinedButton.icon(
                onPressed: () => setState(() => _cwRevealed = true),
                icon: const Icon(Icons.visibility_off_outlined, size: 16),
                label: Text('$cw — tap to show'),
              )
            else ...[
              if (hasCw)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    cw,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (p.body.isNotEmpty) Text(p.body),
              if (p.media.isNotEmpty) ...[
                const SizedBox(height: 8),
                PostMediaView(media: p.media),
              ],
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _reacted ? Icons.favorite : Icons.favorite_border,
                    size: 20,
                    color: _reacted ? scheme.primary : null,
                  ),
                  tooltip: 'Like',
                  onPressed: _toggleReaction,
                ),
                _ReplyButton(count: _replyCount, onPressed: _reply),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.repeat,
                    size: 20,
                    color: _reposted ? scheme.primary : null,
                  ),
                  tooltip: 'Repost',
                  onPressed: _toggleRepost,
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.help_outline, size: 19),
                  tooltip: 'Why am I seeing this?',
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Feed transparency — Phase 5'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyButton extends StatelessWidget {
  const _ReplyButton({required this.count, required this.onPressed});
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      icon: const Icon(Icons.mode_comment_outlined, size: 18),
      label: Text(count == 0 ? '' : '$count'),
    );
  }
}

class _VisibilityChip extends StatelessWidget {
  const _VisibilityChip({required this.visibility});
  final String visibility;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (visibility) {
      'public' => (Icons.public, 'Public'),
      'followers' => (Icons.people_outline, 'Followers'),
      'mentioned' => (Icons.alternate_email, 'Mentioned'),
      _ => (Icons.lock_outline, 'Circles'),
    };
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: label,
      child: Icon(icon, size: 15, color: c),
    );
  }
}

String _relativeTime(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}
