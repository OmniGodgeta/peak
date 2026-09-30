import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/federation_repository.dart';
import '../../data/report_repository.dart';

final _followingProvider = FutureProvider<List<RemoteAccount>>(
  (ref) => ref.watch(federationRepositoryProvider).following(),
);
final _blocklistProvider = FutureProvider<List<BlockedServer>>(
  (ref) => ref.watch(federationRepositoryProvider).blocklist(),
);

/// Me → Federation: whether people on other servers (Mastodon and friends)
/// can follow you, who you follow there, moving accounts, and the servers
/// this instance refuses to talk to.
class FederationScreen extends ConsumerStatefulWidget {
  const FederationScreen({super.key});

  @override
  ConsumerState<FederationScreen> createState() => _FederationScreenState();
}

class _FederationScreenState extends ConsumerState<FederationScreen> {
  final _follow = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _follow.dispose();
    super.dispose();
  }

  FederationRepository get _repo => ref.read(federationRepositoryProvider);

  Future<void> _run(Future<void> Function() f, {String? done}) async {
    setState(() => _busy = true);
    try {
      await f();
      if (done != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(federationError(e))));
      }
    } finally {
      ref.invalidate(federationStatusProvider);
      ref.invalidate(_followingProvider);
      ref.invalidate(_blocklistProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editAliases(List<String> current) async {
    final c = TextEditingController(text: current.join('\n'));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Moving here from another server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Add the address of your old account (its https:// profile '
              'URL), one per line. Then start the move from the old server; '
              'your followers there will follow you here.',
            ),
            TextField(
              controller: c,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'https://mastodon.example/users/you',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    c.dispose();
    if (result == null) return;
    final aliases = [
      for (final l in result.split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    await _run(() => _repo.setAliases(aliases), done: 'Saved');
  }

  Future<void> _moveOut() async {
    final c = TextEditingController();
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to another server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your followers on other servers will be asked to follow your '
              'new account. On the new account, first add this account as '
              'an alias ("also known as"). Your posts stay here.',
            ),
            TextField(
              controller: c,
              decoration: const InputDecoration(hintText: '@you@new.server'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Move'),
          ),
        ],
      ),
    );
    c.dispose();
    if (target == null || target.trim().isEmpty) return;
    await _run(
      () => _repo.moveTo(target.trim()),
      done: 'Move sent to your followers',
    );
  }

  Future<void> _block({required bool staff}) async {
    final d = TextEditingController();
    final r = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block a server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: d,
              decoration: const InputDecoration(labelText: 'Domain'),
            ),
            TextField(
              controller: r,
              decoration: const InputDecoration(
                labelText: 'Reason (shown publicly)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (ok == true && d.text.trim().isNotEmpty) {
      await _run(
        () => _repo.setBlocked(d.text.trim(), true, reason: r.text.trim()),
      );
    }
    d.dispose();
    r.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(federationStatusProvider);
    final isStaff = ref.watch(amIStaffProvider).asData?.value == true;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Federation')),
      body: status.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (s) {
          if (s == null) return const SizedBox.shrink();
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Federation connects Peak to other social servers that speak '
                  'ActivityPub, like Mastodon. It\'s off unless you turn it '
                  'on, and only your public posts ever leave Peak.',
                  style: text.bodyMedium,
                ),
              ),
              if (!s.instanceOn)
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('This Peak server isn\'t connected yet'),
                  subtitle: Text(
                    'The operator turns federation on once Peak has a public '
                    'address. You can set this up now; nothing is sent until then.',
                  ),
                ),
              SwitchListTile(
                title: const Text('Let people on other servers follow me'),
                subtitle: Text(
                  s.isTeen
                      ? 'Not available for teen accounts.'
                      : '${s.remoteFollowers} follower(s) elsewhere',
                ),
                value: s.federated,
                onChanged: s.isTeen || _busy
                    ? null
                    : (v) => _run(() => _repo.setFederated(v)),
              ),
              if (s.federated && s.instanceOn) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    'Follow someone elsewhere',
                    style: text.titleSmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _follow,
                          decoration: const InputDecoration(
                            hintText: '@someone@mastodon.social',
                          ),
                          keyboardType: TextInputType.emailAddress,
                        ),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => _repo.follow(_follow.text.trim()),
                                done: 'Follow request sent',
                              ),
                        child: const Text('Follow'),
                      ),
                    ],
                  ),
                ),
                ref
                    .watch(_followingProvider)
                    .when(
                      loading: () => const SizedBox.shrink(),
                      error: (e, _) => const SizedBox.shrink(),
                      data: (list) => Column(
                        children: [
                          for (final a in list)
                            ListTile(
                              leading: CircleAvatar(
                                backgroundImage: a.icon != null
                                    ? NetworkImage(a.icon!)
                                    : null,
                                child: a.icon == null
                                    ? const Icon(Icons.public)
                                    : null,
                              ),
                              title: Text(a.name ?? a.handle),
                              subtitle: Text(
                                '@${a.handle}${a.accepted ? '' : ' · pending'}',
                              ),
                              trailing: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _run(() => _repo.unfollow(a.id)),
                                child: const Text('Unfollow'),
                              ),
                            ),
                        ],
                      ),
                    ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text('Moving here from another server'),
                  subtitle: Text(
                    s.alsoKnownAs.isEmpty
                        ? 'No old accounts linked'
                        : s.alsoKnownAs.join('\n'),
                  ),
                  onTap: _busy ? null : () => _editAliases(s.alsoKnownAs),
                ),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Move to another server'),
                  subtitle: Text(
                    s.movedTo == null
                        ? 'Tell your followers where you went'
                        : 'Moved to ${s.movedTo}',
                  ),
                  onTap: _busy ? null : _moveOut,
                ),
              ],
              const Divider(),
              ListTile(
                title: Text(
                  'Servers this Peak doesn\'t talk to',
                  style: text.titleSmall,
                ),
                subtitle: const Text(
                  'Published so you know who\'s blocked and why',
                ),
                trailing: isStaff
                    ? IconButton(
                        tooltip: 'Block a server',
                        icon: const Icon(Icons.add),
                        onPressed: _busy ? null : () => _block(staff: true),
                      )
                    : null,
              ),
              ref
                  .watch(_blocklistProvider)
                  .when(
                    loading: () => const SizedBox.shrink(),
                    error: (e, _) => const SizedBox.shrink(),
                    data: (list) => list.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: Text('None.'),
                          )
                        : Column(
                            children: [
                              for (final b in list)
                                ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.block),
                                  title: Text(b.domain),
                                  subtitle: b.reason == null
                                      ? null
                                      : Text(b.reason!),
                                  trailing: isStaff
                                      ? TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => _run(
                                                  () => _repo.setBlocked(
                                                    b.domain,
                                                    false,
                                                  ),
                                                ),
                                          child: const Text('Unblock'),
                                        )
                                      : null,
                                ),
                            ],
                          ),
                  ),
            ],
          );
        },
      ),
    );
  }
}
