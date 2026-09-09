import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/avatar.dart';
import '../../../data/modmail_repository.dart';
import 'modmail_thread_screen.dart';

/// A community's modmail queue (moderators only). Tabs for open / closed / all.
class CommunityModmailScreen extends ConsumerStatefulWidget {
  const CommunityModmailScreen({super.key, required this.communityId});
  final String communityId;

  @override
  ConsumerState<CommunityModmailScreen> createState() =>
      _CommunityModmailScreenState();
}

class _CommunityModmailScreenState extends ConsumerState<CommunityModmailScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  static const _states = ['open', 'closed', 'all'];

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Modmail'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Open'),
            Tab(text: 'Closed'),
            Tab(text: 'All'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          for (final state in _states)
            _Queue(communityId: widget.communityId, state: state),
        ],
      ),
    );
  }
}

class _Queue extends ConsumerWidget {
  const _Queue({required this.communityId, required this.state});
  final String communityId;
  final String state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threads = ref.watch(
      communityModmailThreadsProvider((communityId, state)),
    );
    return RefreshIndicator(
      onRefresh: () async =>
          ref.invalidate(communityModmailThreadsProvider((communityId, state))),
      child: threads.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(
          children: [
            Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
          ],
        ),
        data: (list) {
          if (list.isEmpty) {
            return ListView(
              children: const [
                Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('Nothing here.')),
                ),
              ],
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) => _ThreadTile(thread: list[i]),
          );
        },
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({required this.thread});
  final ModmailThread thread;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: AvatarCircle(
        name: thread.memberName,
        path: thread.memberAvatarPath,
        radius: 18,
      ),
      title: Text(thread.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${thread.memberName} · ${thread.lastSnippet ?? ""}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (thread.awaitingModerator)
            Icon(Icons.circle, size: 10, color: scheme.primary)
          else if (!thread.isOpen)
            Icon(Icons.check, size: 16, color: scheme.onSurfaceVariant),
          if (thread.memberState == 'banned')
            Text('banned', style: TextStyle(fontSize: 11, color: scheme.error)),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ModmailThreadScreen(thread: thread, viewerIsMod: true),
        ),
      ),
    );
  }
}
