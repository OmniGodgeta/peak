import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/report_repository.dart';
import '../communities/community_screen.dart';
import '../feed/thread_screen.dart';

/// The moderation queue. Site staff see everything; a community moderator sees
/// non-urgent reports about their community's posts.
class ReviewQueueScreen extends ConsumerStatefulWidget {
  const ReviewQueueScreen({super.key});

  @override
  ConsumerState<ReviewQueueScreen> createState() => _ReviewQueueScreenState();
}

class _ReviewQueueScreenState extends ConsumerState<ReviewQueueScreen>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  static const _statuses = ['open', 'reviewing', 'all'];

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Open'),
            Tab(text: 'Reviewing'),
            Tab(text: 'All'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [for (final s in _statuses) _Queue(status: s)],
      ),
    );
  }
}

class _Queue extends ConsumerWidget {
  const _Queue({required this.status});
  final String status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(reviewQueueProvider(status));
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(reviewQueueProvider(status)),
      child: items.when(
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
                  child: Center(child: Text('Nothing to review.')),
                ),
              ],
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) => _ReportTile(
              item: list[i],
              onChanged: () {
                for (final s in _ReviewQueueScreenState._statuses) {
                  ref.invalidate(reviewQueueProvider(s));
                }
              },
            ),
          );
        },
      ),
    );
  }
}

class _ReportTile extends ConsumerWidget {
  const _ReportTile({required this.item, required this.onChanged});
  final QueueItem item;
  final VoidCallback onChanged;

  void _openSubject(BuildContext context) {
    final route = switch (item.subjectKind) {
      'post' => MaterialPageRoute<void>(
        builder: (_) => ThreadScreen(rootId: item.subjectId),
      ),
      'community' =>
        item.communitySlug == null
            ? null
            : MaterialPageRoute<void>(
                builder: (_) => CommunityScreen(slug: item.communitySlug!),
              ),
      _ => null,
    };
    if (route != null) Navigator.of(context).push(route);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    Future<void> resolve(String status) async {
      final resolution = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final c = TextEditingController();
          return AlertDialog(
            title: Text(status == 'actioned' ? 'Mark actioned' : 'Dismiss'),
            content: TextField(
              controller: c,
              decoration: const InputDecoration(hintText: 'Note (optional)'),
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
          );
        },
      );
      if (resolution == null) return;
      try {
        await ref
            .read(reportRepositoryProvider)
            .resolve(
              item.id,
              status,
              resolution: resolution.isEmpty ? null : resolution,
            );
        onChanged();
      } on Exception catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }

    return ListTile(
      leading: item.isUrgent
          ? Icon(Icons.priority_high, color: scheme.error)
          : const Icon(Icons.flag_outlined),
      title: Text('${_reasonLabel(item.reason)} · ${item.subjectKind}'),
      subtitle: Text(
        [
          if (item.detail != null && item.detail!.isNotEmpty)
            '“${item.detail}”',
          if (item.reportCount > 1) '${item.reportCount} reports',
          if (item.communitySlug != null) 'c/${item.communitySlug}',
          if (item.reporterHandle != null) 'by @${item.reporterHandle}',
        ].join(' · '),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'open') {
            _openSubject(context);
          } else {
            resolve(v);
          }
        },
        itemBuilder: (_) => [
          if (item.subjectKind == 'post' || item.subjectKind == 'community')
            const PopupMenuItem(value: 'open', child: Text('Open')),
          const PopupMenuItem(value: 'reviewing', child: Text('Reviewing')),
          const PopupMenuItem(value: 'actioned', child: Text('Actioned')),
          const PopupMenuItem(value: 'dismissed', child: Text('Dismiss')),
        ],
      ),
    );
  }
}

String _reasonLabel(String key) => ReportReason.values
    .firstWhere((r) => r.key == key, orElse: () => ReportReason.other)
    .label;
