import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/community_repository.dart';
import '../../data/data_repository.dart';
import '../../data/feed_repository.dart';
import '../../data/labeler_repository.dart';
import '../../data/people_repository.dart';
import '../../data/supabase_providers.dart';
import '../../app/avatar.dart';
import '../../wellbeing/wellbeing.dart';
import '../moderation/labeler_edit_screen.dart';
import '../moderation/report_sheet.dart';
import '../compose/compose_screen.dart';
import '../profile/user_profile_screen.dart';
import 'article_screen.dart';
import 'post_body.dart';
import 'post_media_view.dart';
import 'thread_screen.dart';

/// A single post in the feed. Counts stay hidden by default (docs/PRODUCT.md
/// §2.6) for likes/reposts; reply count is shown because it's conversational
/// context, not a vanity metric.
class PostCard extends ConsumerStatefulWidget {
  const PostCard({
    super.key,
    required this.post,
    this.tappable = true,
    this.moderatorControls = false,
    this.showChannel = false,
  });
  final FeedPost post;

  /// Show a `#channel` chip (community "All" view, where posts span channels).
  final bool showChannel;

  /// In a thread the current post shouldn't re-open the thread on tap.
  final bool tappable;

  /// Shown in a community feed when the viewer moderates it — adds Label /
  /// Remove to the overflow menu.
  final bool moderatorControls;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  late bool _reacted = widget.post.viewerReacted;
  late bool _reposted = widget.post.viewerReposted;
  late int _replyCount = widget.post.replyCount;
  bool _cwRevealed = false;
  bool _labelRevealed = false;
  bool _deleted = false;

  void _openProfile(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UserProfileScreen(handle: widget.post.authorHandle),
      ),
    );
  }

  void _openThread() {
    final p = widget.post;
    if (p.longForm && p.replyTo == null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ArticleScreen(article: p)),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ThreadScreen(rootId: p.replyTo ?? p.id),
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

  bool get _isMine => widget.post.authorId == ref.read(currentUserProvider)?.id;

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this post?'),
        content: const Text(
          'It’s removed for everyone right away. You have 30 days to restore '
          'it from Settings → Your data → Recently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(dataRepositoryProvider).deletePost(widget.post.id);
      if (!mounted) return;
      setState(() => _deleted = true);
      ref.read(feedRevisionProvider.notifier).bump();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _undoDelete() async {
    try {
      await ref.read(dataRepositoryProvider).restorePost(widget.post.id);
      if (!mounted) return;
      setState(() => _deleted = false);
      ref.read(feedRevisionProvider.notifier).bump();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _moderate(String action) async {
    final repo = ref.read(communityRepositoryProvider);
    try {
      if (action == 'remove') {
        final reason = await _askReason('Remove this post?');
        if (reason == null) return;
        await repo.removePost(widget.post.id, reason: reason);
        if (mounted) setState(() => _deleted = true);
      } else if (action == 'unlabel') {
        await repo.unlabelPost(widget.post.id);
      } else {
        // action is the label text
        await repo.labelPost(widget.post.id, action);
      }
      ref.invalidate(feedRevisionProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(action == 'remove' ? 'Removed' : 'Done')),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Apply a label from one of the viewer's own labelers to this post.
  Future<void> _labelPost() async {
    final repo = ref.read(labelerRepositoryProvider);
    final mine = (await ref.read(myLabelersProvider.future))
        .where((l) => l.owned)
        .toList();
    if (!mounted) return;
    if (mine.isEmpty) {
      final make = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Create a labeler first'),
          content: const Text(
            'Labels come from a labeler you run — a named set of labels other '
            'people can subscribe to. Create one to start labelling posts.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      );
      if (make == true && mounted) {
        await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => const LabelerEditScreen()),
        );
      }
      return;
    }

    final picked = await showModalBottomSheet<({String labelerId, String key})>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text('Label this post'),
          ),
          for (final l in mine)
            _LabelerLabels(
              labelerId: l.id,
              labelerName: l.name,
              onPick: (key) => Navigator.pop(ctx, (labelerId: l.id, key: key)),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await repo.applyLabel(
        labelerId: picked.labelerId,
        postId: widget.post.id,
        labelKey: picked.key,
      );
      ref.read(labelerRevisionProvider.notifier).bump();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Label applied')));
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<String?> _askReason(String title) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 500,
          decoration: const InputDecoration(
            hintText: 'Reason (shown in the mod log)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  Future<void> _togglePin() async {
    final repo = ref.read(dataRepositoryProvider);
    try {
      if (widget.post.isPinned) {
        await repo.unpinPost(widget.post.id);
      } else {
        await repo.pinPost(widget.post.id);
      }
      ref.invalidate(postsByProvider(widget.post.authorId));
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cw = p.contentWarning;
    final hasCw = cw != null && cw.isNotEmpty;

    final labels =
        ref.watch(postLabelsProvider(p.id)).asData?.value ??
        const <PostLabel>[];
    final hideLabel = labels
        .where((l) => l.severity == LabelSeverity.hide)
        .firstOrNull;
    final blurred = hideLabel != null && !_labelRevealed;

    if (_deleted) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(
              Icons.delete_outline,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              'Post deleted',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton(onPressed: _undoDelete, child: const Text('Undo')),
          ],
        ),
      );
    }

    return InkWell(
      onTap: widget.tappable ? _openThread : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.isPinned)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.push_pin,
                      size: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Pinned',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.showChannel && p.channelName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '#${p.channelName}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (p.communityLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.label_outline, size: 14),
                      label: Text(p.communityLabel!),
                      visualDensity: VisualDensity.compact,
                      side: BorderSide.none,
                      backgroundColor: scheme.secondaryContainer,
                    ),
                    if (p.communityLabelNote != null &&
                        p.communityLabelNote!.isNotEmpty)
                      Text(
                        p.communityLabelNote!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            if (labels.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [for (final l in labels) _LabelChip(label: l)],
                ),
              ),
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
                            if (p.authorFlair != null &&
                                p.authorFlair!.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  p.authorFlair!,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.primary,
                                  ),
                                ),
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
            if (blurred)
              OutlinedButton.icon(
                onPressed: () => setState(() => _labelRevealed = true),
                icon: const Icon(Icons.visibility_off_outlined, size: 16),
                label: Text(
                  '${hideLabel.labelName} — labelled by ${hideLabel.labelerName}. '
                  'Tap to show',
                ),
              )
            else if (hasCw && !_cwRevealed)
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
              if (p.longForm && p.replyTo == null)
                _ArticlePreview(post: p)
              else ...[
                if (p.body.isNotEmpty)
                  PostBody(text: p.body, showPreview: p.replyTo == null),
                if (p.media.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  PostMediaView(media: p.media),
                ],
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
                _ReplyButton(
                  count:
                      ref.watch(wellbeingProvider.select((w) => w.hideCounts))
                      ? -1
                      : _replyCount,
                  onPressed: _reply,
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
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, size: 19),
                  tooltip: 'More',
                  onSelected: (v) {
                    switch (v) {
                      case 'why':
                        showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Why am I seeing this?'),
                            content: Text(
                              p.reason ??
                                  (p.channelName != null
                                      ? 'A post in #${p.channelName}, a channel '
                                            'of a community you can see.'
                                      : "It's in a thread or community you "
                                            'opened. The home feed is only '
                                            'people you follow — never ranked '
                                            'or injected.'),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('OK'),
                              ),
                            ],
                          ),
                        );
                      case 'report':
                        showReportSheet(
                          context,
                          kind: 'post',
                          subjectId: widget.post.id,
                          what: 'this post',
                        );
                      case 'apply-label':
                        _labelPost();
                      case 'pin':
                        _togglePin();
                      case 'delete':
                        _confirmDelete();
                      case 'mod-remove':
                        _moderate('remove');
                      case 'mod-unlabel':
                        _moderate('unlabel');
                      default:
                        if (v.startsWith('label:')) {
                          _moderate(v.substring(6));
                        }
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'why',
                      child: Text('Why am I seeing this?'),
                    ),
                    if (!_isMine)
                      const PopupMenuItem(
                        value: 'report',
                        child: Text('Report post'),
                      ),
                    const PopupMenuItem(
                      value: 'apply-label',
                      child: Text('Label this post…'),
                    ),
                    if (_isMine)
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(
                          p.isPinned ? 'Unpin from profile' : 'Pin to profile',
                        ),
                      ),
                    if (_isMine)
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          'Delete post',
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    if (widget.moderatorControls) ...[
                      const PopupMenuDivider(),
                      if (p.communityLabel == null)
                        for (final l in const [
                          'off-topic',
                          'unverified',
                          'satire',
                          'spoiler',
                        ])
                          PopupMenuItem(
                            value: 'label:$l',
                            child: Text('Label “$l”'),
                          )
                      else
                        const PopupMenuItem(
                          value: 'mod-unlabel',
                          child: Text('Remove label'),
                        ),
                      PopupMenuItem(
                        value: 'mod-remove',
                        child: Text(
                          'Remove (moderator)',
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A single labeler's label shown on a post — quiet for info, bold for warn,
/// eye-off for a hide label. Always names the labeler.
class _LabelChip extends StatelessWidget {
  const _LabelChip({required this.label});
  final PostLabel label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, bg, fg) = switch (label.severity) {
      LabelSeverity.hide => (
        Icons.visibility_off_outlined,
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      LabelSeverity.warn => (
        Icons.warning_amber_outlined,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      LabelSeverity.info => (
        Icons.info_outline,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return Tooltip(
      message: label.note?.isNotEmpty == true
          ? '${label.labelerName}: ${label.note}'
          : 'Labelled by ${label.labelerName}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
            Text(
              label.labelName,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: fg),
            ),
            Text(
              '  ·  ${label.labelerName}',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: fg.withValues(alpha: 0.7)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The labels of one owned labeler, as tappable rows in the "label this post"
/// sheet.
class _LabelerLabels extends ConsumerWidget {
  const _LabelerLabels({
    required this.labelerId,
    required this.labelerName,
    required this.onPick,
  });
  final String labelerId;
  final String labelerName;
  final void Function(String key) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(labelerLabelsProvider(labelerId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          child: Text(
            labelerName.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        labels.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) =>
              Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
          data: (list) => list.isEmpty
              ? const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text('This labeler has no labels yet.'),
                )
              : Column(
                  children: [
                    for (final l in list)
                      ListTile(
                        dense: true,
                        leading: Icon(_sevIcon(l.severity)),
                        title: Text(l.name),
                        onTap: () => onPick(l.key),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

IconData _sevIcon(LabelSeverity s) => switch (s) {
  LabelSeverity.hide => Icons.visibility_off_outlined,
  LabelSeverity.warn => Icons.warning_amber_outlined,
  LabelSeverity.info => Icons.info_outline,
};

class _ArticlePreview extends StatelessWidget {
  const _ArticlePreview({required this.post});
  final FeedPost post;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Strip the light markdown markers so the feed lede reads as prose.
    final lede = post.body
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^\s*(#{1,2}\s+|[-*]\s+)'), ''))
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.article_outlined, size: 13, color: scheme.primary),
            const SizedBox(width: 4),
            Text(
              'ARTICLE',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          post.title ?? 'Untitled',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (lede.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            lede,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (post.media.isNotEmpty) ...[
          const SizedBox(height: 8),
          PostMediaView(media: post.media),
        ],
        const SizedBox(height: 6),
        Text(
          'Read article →',
          style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary),
        ),
      ],
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
      label: Text(count <= 0 ? '' : '$count'),
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
