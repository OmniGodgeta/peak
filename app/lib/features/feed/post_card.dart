import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feed_repository.dart';
import '../profile/user_profile_screen.dart';

/// A single post in the feed. Counts stay hidden by default (docs/PRODUCT.md
/// §2.6) — the icons show the viewer's own state, not a public tally.
class PostCard extends ConsumerStatefulWidget {
  const PostCard({super.key, required this.post});
  final FeedPost post;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  late bool _reacted = widget.post.viewerReacted;
  late bool _reposted = widget.post.viewerReposted;
  bool _cwRevealed = false;

  void _openProfile(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UserProfileScreen(handle: widget.post.authorHandle),
      ),
    );
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => _openProfile(context),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: scheme.primaryContainer,
                  child: Text(
                    p.authorName.characters.first.toUpperCase(),
                    style: TextStyle(color: scheme.onPrimaryContainer),
                  ),
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
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.mode_comment_outlined, size: 19),
                tooltip: 'Reply',
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Replies — Phase 1')),
                ),
              ),
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
                  const SnackBar(content: Text('Feed transparency — Phase 5')),
                ),
              ),
            ],
          ),
        ],
      ),
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
