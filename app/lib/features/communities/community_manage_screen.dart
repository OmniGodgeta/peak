import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/community_repository.dart';
import 'community_channels_screen.dart';
import 'community_edit_screen.dart';
import 'mod_log_screen.dart';
import 'modmail/community_modmail_screen.dart';

/// Moderator tools for one community: join requests, the member roster with
/// role controls, and the ban list. Admins also get "Edit community".
class CommunityManageScreen extends ConsumerWidget {
  const CommunityManageScreen({super.key, required this.community});
  final Community community;

  CommunityRepository _repo(WidgetRef ref) =>
      ref.read(communityRepositoryProvider);

  void _refresh(WidgetRef ref) {
    ref.invalidate(communityPendingProvider(community.id));
    ref.invalidate(communityRosterProvider(community.id));
    ref.invalidate(communityBannedProvider(community.id));
    ref.invalidate(communityViewProvider(community.slug));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(communityPendingProvider(community.id));
    final roster = ref.watch(communityRosterProvider(community.id));
    final banned = ref.watch(communityBannedProvider(community.id));

    return Scaffold(
      appBar: AppBar(title: Text('Manage ${community.name}')),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(ref),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Modmail'),
              subtitle: const Text('Private threads from members'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CommunityModmailScreen(communityId: community.id),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Moderation log'),
              subtitle: const Text('Every mod action, visible to members'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ModLogScreen(communityId: community.id),
                ),
              ),
            ),
            if (community.isAdmin)
              ListTile(
                leading: const Icon(Icons.tag),
                title: const Text('Channels'),
                subtitle: const Text('Split the feed into topics'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        CommunityChannelsScreen(community: community),
                  ),
                ),
              ),
            if (community.isAdmin)
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Edit community'),
                subtitle: const Text('Name, description, topics, join policy'),
                onTap: () async {
                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => CommunityEditScreen(community: community),
                    ),
                  );
                  if (saved == true) {
                    ref.invalidate(communityViewProvider(community.slug));
                  }
                },
              ),

            _SectionHeader('Requests', trailing: pending.asData?.value.length),
            pending.when(
              loading: () => const _Loading(),
              error: (e, _) => _Err('$e'),
              data: (list) => list.isEmpty
                  ? const _Empty('No pending requests.')
                  : Column(
                      children: [
                        for (final p in list)
                          _PersonTile(
                            person: p,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.check),
                                  tooltip: 'Approve',
                                  onPressed: () async {
                                    await _repo(ref)
                                        .approve(community.id, p.memberId);
                                    _refresh(ref);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close),
                                  tooltip: 'Decline',
                                  onPressed: () async {
                                    await _repo(ref)
                                        .decline(community.id, p.memberId);
                                    _refresh(ref);
                                  },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),

            const _SectionHeader('Members'),
            roster.when(
              loading: () => const _Loading(),
              error: (e, _) => _Err('$e'),
              data: (list) => Column(
                children: [
                  for (final p in list)
                    _PersonTile(
                      person: p,
                      subtitle: p.role == 'member' ? null : p.role,
                      trailing: _MemberMenu(
                        community: community,
                        person: p,
                        onDone: () => _refresh(ref),
                      ),
                    ),
                ],
              ),
            ),

            if ((banned.asData?.value.isNotEmpty ?? false)) ...[
              const _SectionHeader('Banned'),
              for (final p in banned.asData!.value)
                _PersonTile(
                  person: p,
                  trailing: TextButton(
                    onPressed: () async {
                      await _repo(ref).unban(community.id, p.memberId);
                      _refresh(ref);
                    },
                    child: const Text('Unban'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemberMenu extends ConsumerWidget {
  const _MemberMenu({
    required this.community,
    required this.person,
    required this.onDone,
  });
  final Community community;
  final CommunityPerson person;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(communityRepositoryProvider);
    final scheme = Theme.of(context).colorScheme;

    Future<void> run(Future<void> Function() op) async {
      try {
        await op();
        onDone();
      } on Exception catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }

    return PopupMenuButton<String>(
      onSelected: (v) => switch (v) {
        'mod' => run(
          () => repo.setRole(community.id, person.memberId, 'moderator'),
        ),
        'admin' => run(
          () => repo.setRole(community.id, person.memberId, 'admin'),
        ),
        'demote' => run(
          () => repo.setRole(community.id, person.memberId, 'member'),
        ),
        'remove' => run(() => repo.remove(community.id, person.memberId)),
        'ban' => run(
          () => repo.remove(community.id, person.memberId, ban: true),
        ),
        _ => null,
      },
      itemBuilder: (_) => [
        if (community.isAdmin && person.role == 'member')
          const PopupMenuItem(value: 'mod', child: Text('Make moderator')),
        if (community.isAdmin && person.role == 'member')
          const PopupMenuItem(value: 'admin', child: Text('Make admin')),
        if (community.isAdmin && person.role != 'member')
          const PopupMenuItem(value: 'demote', child: Text('Remove role')),
        PopupMenuItem(
          value: 'remove',
          child: Text('Remove', style: TextStyle(color: scheme.error)),
        ),
        PopupMenuItem(
          value: 'ban',
          child: Text('Ban', style: TextStyle(color: scheme.error)),
        ),
      ],
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person, this.subtitle, this.trailing});
  final CommunityPerson person;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: AvatarCircle(
        name: person.name,
        path: person.avatarPath,
        radius: 18,
      ),
      title: Text(person.name),
      subtitle: Text(subtitle ?? person.fqHandle),
      trailing: trailing,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, {this.trailing});
  final String label;
  final int? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          if (trailing != null && trailing! > 0) ...[
            const SizedBox(width: 6),
            Badge(label: Text('$trailing')),
          ],
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(20),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class _Err extends StatelessWidget {
  const _Err(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Text(text));
}
