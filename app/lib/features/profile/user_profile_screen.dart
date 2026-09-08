import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feed_repository.dart';
import '../../data/people_repository.dart';
import '../feed/post_card.dart';

/// Someone else's profile (or your own, viewed by handle): identity, a follow
/// button, and their posts.
class UserProfileScreen extends ConsumerWidget {
  const UserProfileScreen({super.key, required this.handle});
  final String handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileViewProvider(handle));

    return Scaffold(
      appBar: AppBar(title: Text('@$handle')),
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
              CircleAvatar(
                radius: 32,
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  p.name.characters.first.toUpperCase(),
                  style: TextStyle(
                    fontSize: 26,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
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
              if (!p.isSelf)
                FilledButton.tonal(
                  onPressed: _busy ? null : _toggle,
                  child: Text(_following ? 'Following' : 'Follow'),
                ),
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
        return Column(
          children: [
            for (final post in list) ...[
              PostCard(post: post),
              const Divider(height: 1),
            ],
          ],
        );
      },
    );
  }
}
