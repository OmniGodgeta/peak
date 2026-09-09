import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/community_repository.dart';
import '../compose/compose_screen.dart';
import '../feed/post_card.dart';
import 'community_manage_screen.dart';
import 'mod_log_screen.dart';

/// One community: its header, join/leave control, and its feed.
class CommunityScreen extends ConsumerWidget {
  const CommunityScreen({super.key, required this.slug});
  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final community = ref.watch(communityViewProvider(slug));

    final c = community.asData?.value;
    return Scaffold(
      appBar: AppBar(
        title: Text('c/$slug'),
        actions: [
          if (c != null && c.isMember)
            IconButton(
              tooltip: 'Moderation log',
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ModLogScreen(communityId: c.id),
                ),
              ),
            ),
          if (c != null && c.canModerate)
            IconButton(
              tooltip: 'Manage',
              icon: c.pendingCount > 0
                  ? Badge(
                      label: Text('${c.pendingCount}'),
                      child: const Icon(Icons.shield_outlined),
                    )
                  : const Icon(Icons.shield_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CommunityManageScreen(community: c),
                ),
              ),
            ),
        ],
      ),
      body: community.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (c) {
          if (c == null) {
            return const Center(
              child: Text('This community is not available.'),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(communityViewProvider(slug));
              ref.invalidate(communityFeedProvider(c.id));
            },
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _Header(community: c)),
                const SliverToBoxAdapter(child: Divider(height: 1)),
                _Feed(community: c),
              ],
            ),
          );
        },
      ),
      floatingActionButton: community.asData?.value?.isMember == true
          ? FloatingActionButton(
              onPressed: () async {
                final c = community.asData!.value!;
                final posted = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ComposeScreen(communityId: c.id, communityName: c.name),
                  ),
                );
                if (posted == true) ref.invalidate(communityFeedProvider(c.id));
              },
              child: const Icon(Icons.edit),
            )
          : null,
    );
  }
}

class _Header extends ConsumerStatefulWidget {
  const _Header({required this.community});
  final Community community;

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  bool _busy = false;

  Future<void> _join() async {
    setState(() => _busy = true);
    try {
      final state = await ref
          .read(communityRepositoryProvider)
          .join(widget.community.id);
      ref.invalidate(communityViewProvider(widget.community.slug));
      ref.invalidate(myCommunitiesProvider);
      if (mounted && state == 'request') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request sent — a moderator will review it.'),
          ),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    setState(() => _busy = true);
    try {
      await ref.read(communityRepositoryProvider).leave(widget.community.id);
      ref.invalidate(communityViewProvider(widget.community.slug));
      ref.invalidate(myCommunitiesProvider);
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
    final c = widget.community;
    final theme = Theme.of(context);

    final Widget action;
    if (_busy) {
      action = const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (c.isMember) {
      action = OutlinedButton(onPressed: _leave, child: const Text('Leave'));
    } else if (c.isPending) {
      action = const OutlinedButton(onPressed: null, child: Text('Requested'));
    } else {
      action = FilledButton(
        onPressed: _join,
        child: Text(
          c.joinPolicy == CommunityJoinPolicy.request
              ? 'Request to join'
              : 'Join',
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(c.name, style: theme.textTheme.headlineSmall),
              ),
              action,
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${c.memberCount} member${c.memberCount == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (c.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(c.description),
          ],
          if (c.topics.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final t in c.topics)
                  Chip(
                    label: Text(t),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide.none,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Feed extends ConsumerWidget {
  const _Feed({required this.community});
  final Community community;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(communityFeedProvider(community.id));
    return feed.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SliverToBoxAdapter(
        child: Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
      ),
      data: (posts) {
        if (posts.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  community.isMember
                      ? 'No posts yet — start the conversation.'
                      : 'No posts yet.',
                ),
              ),
            ),
          );
        }
        return SliverList.separated(
          itemCount: posts.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) => PostCard(
            post: posts[i],
            moderatorControls: community.canModerate,
          ),
        );
      },
    );
  }
}
