import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/feed_repository.dart';
import '../../data/messaging_repository.dart';
import '../../data/people_repository.dart';
import '../../data/personhood_repository.dart';
import '../../data/report_repository.dart';
import '../feed/post_card.dart';
import '../messaging/chat_screen.dart';
import '../moderation/report_sheet.dart';

/// Someone else's profile (or your own, viewed by handle): identity, a follow
/// button, and their posts.
class UserProfileScreen extends ConsumerWidget {
  const UserProfileScreen({super.key, required this.handle});
  final String handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileViewProvider(handle));

    final pv = profile.asData?.value;
    return Scaffold(
      appBar: AppBar(
        title: Text('@$handle'),
        actions: [
          if (pv != null && !pv.isSelf)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'report') {
                  showReportSheet(
                    context,
                    kind: 'profile',
                    subjectId: pv.id,
                    what: '@$handle',
                  );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'report', child: Text('Report account')),
              ],
            ),
        ],
      ),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (p) {
          if (p == null) {
            return const Center(child: Text('This account is not available.'));
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(profileViewProvider(handle));
              ref.invalidate(postsByProvider(p.id));
            },
            child: ListView(
              children: [
                _Header(profile: p),
                const Divider(height: 1),
                _Posts(authorId: p.id),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Header extends ConsumerStatefulWidget {
  const _Header({required this.profile});
  final ProfileView profile;

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  late bool _following = widget.profile.isFollowing;
  bool _busy = false;

  Future<void> _message(ProfileView p) async {
    setState(() => _busy = true);
    try {
      final convId = await ref.read(messagingRepositoryProvider).startDm(p.id);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ChatScreen(conversationId: convId, title: p.name, otherId: p.id),
        ),
      );
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final repo = ref.read(peopleRepositoryProvider);
    try {
      if (_following) {
        await repo.unfollow(widget.profile.id);
      } else {
        await repo.follow(widget.profile.id);
      }
      setState(() => _following = !_following);
      ref.invalidate(profileViewProvider(widget.profile.handle));
      ref.read(feedRevisionProvider.notifier).bump();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AvatarCircle(name: p.name, path: p.avatarPath, radius: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            p.name,
                            style: theme.textTheme.titleLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (p.isVerifiedPerson) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: 'Verified person',
                            child: Icon(
                              Icons.verified,
                              size: 16,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                        if (p.isTeen) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.shield_outlined,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ],
                    ),
                    Text(
                      p.fqHandle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (p.followsYou)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Follows you',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (p.bio.isNotEmpty) ...[const SizedBox(height: 12), Text(p.bio)],
          _PersonhoodStrip(handle: p.handle, isSelf: p.isSelf),
          const SizedBox(height: 12),
          Row(
            children: [
              if (p.showFollowCounts || p.isSelf) ...[
                _Count(label: 'followers', value: p.followerCount),
                const SizedBox(width: 16),
                _Count(label: 'following', value: p.followingCount),
                const SizedBox(width: 16),
              ],
              _Count(label: 'posts', value: p.postCount),
              const Spacer(),
              if (!p.isSelf) ...[
                IconButton.outlined(
                  tooltip: 'Message',
                  icon: const Icon(Icons.mail_outline, size: 18),
                  onPressed: _busy ? null : () => _message(p),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _busy ? null : _toggle,
                  child: Text(_following ? 'Following' : 'Follow'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$value ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text: label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Posts extends ConsumerWidget {
  const _Posts({required this.authorId});
  final String authorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posts = ref.watch(postsByProvider(authorId));
    return posts.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) =>
          Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
      data: (list) {
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('No posts yet.')),
          );
        }
        final pinned = list.where((p) => p.isPinned).toList();
        final rest = list.where((p) => !p.isPinned).toList();
        return Column(
          children: [
            for (final post in pinned) ...[
              PostCard(post: post),
              const Divider(height: 1),
            ],
            if (pinned.isNotEmpty && rest.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                alignment: Alignment.centerLeft,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Text(
                  'Posts',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final post in rest) ...[
              PostCard(post: post),
              const Divider(height: 1),
            ],
          ],
        );
      },
    );
  }
}

/// Proof-of-personhood status + vouch / staff controls for one profile.
class _PersonhoodStrip extends ConsumerWidget {
  const _PersonhoodStrip({required this.handle, required this.isSelf});
  final String handle;
  final bool isSelf;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      ref.read(personhoodRevisionProvider.notifier).bump();
      ref.invalidate(profileViewProvider(handle));
    } on Exception catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ph = ref.watch(personhoodOfProvider(handle)).asData?.value;
    if (ph == null) return const SizedBox.shrink();
    final isStaff = ref.watch(amIStaffProvider).asData?.value ?? false;
    final repo = ref.read(personhoodRepositoryProvider);
    final theme = Theme.of(context);

    final line = ph.verified
        ? (ph.method == 'staff'
              ? 'Verified person — confirmed by Peak'
              : 'Verified person — vouched for by ${ph.vouchCount} others')
        : ph.vouchCount > 0
        ? '${ph.vouchCount} of 3 vouches toward verification'
        : 'Not verified';

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ph.verified ? Icons.verified : Icons.person_outline,
                size: 15,
                color: ph.verified
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(child: Text(line, style: theme.textTheme.bodySmall)),
            ],
          ),
          if (!isSelf)
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => _run(
                    context,
                    ref,
                    () =>
                        ph.iVouched ? repo.unvouch(handle) : repo.vouch(handle),
                  ),
                  child: Text(ph.iVouched ? 'Withdraw vouch' : 'Vouch'),
                ),
                if (isStaff)
                  TextButton(
                    onPressed: () => _run(
                      context,
                      ref,
                      () => ph.verified && ph.method == 'staff'
                          ? repo.revoke(handle)
                          : repo.grant(handle),
                    ),
                    child: Text(
                      ph.verified && ph.method == 'staff'
                          ? 'Un-verify (staff)'
                          : 'Verify (staff)',
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
