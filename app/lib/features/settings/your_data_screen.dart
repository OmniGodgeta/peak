import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/data_repository.dart';
import '../../data/feed_repository.dart';
import '../feed/post_media_view.dart';

/// Settings → Your data: the Phase 3 controls — one-click export and the
/// 30-day recently-deleted bin.
class YourDataScreen extends ConsumerStatefulWidget {
  const YourDataScreen({super.key});

  @override
  ConsumerState<YourDataScreen> createState() => _YourDataScreenState();
}

class _YourDataScreenState extends ConsumerState<YourDataScreen> {
  bool _exporting = false;

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final archive = await ref.read(dataRepositoryProvider).requestExport();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Your archive is ready'),
          content: Text(
            '${archive.filename}\n${_size(archive.bytes)}\n\n'
            'The download link works for one hour. It includes your profile, '
            'posts, connections, reactions and message history.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () {
                launchUrl(
                  Uri.parse(archive.url),
                  mode: LaunchMode.externalApplication,
                );
                Navigator.pop(ctx);
              },
              child: const Text('Download'),
            ),
          ],
        ),
      );
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your data')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Export'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Download your data'),
            subtitle: const Text(
              'Everything on your account as a single JSON file',
            ),
            trailing: _exporting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _exporting ? null : _export,
          ),
          const Divider(height: 24),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('Delete'),
          ),
          ListTile(
            leading: const Icon(Icons.restore_from_trash_outlined),
            title: const Text('Recently deleted'),
            subtitle: const Text(
              'Restore a post within 30 days of deleting it',
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RecentlyDeletedScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class RecentlyDeletedScreen extends ConsumerWidget {
  const RecentlyDeletedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deleted = ref.watch(deletedPostsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Recently deleted')),
      body: deleted.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('Nothing here.'));
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(deletedPostsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _DeletedRow(post: list[i]),
            ),
          );
        },
      ),
    );
  }
}

class _DeletedRow extends ConsumerStatefulWidget {
  const _DeletedRow({required this.post});
  final DeletedPost post;

  @override
  ConsumerState<_DeletedRow> createState() => _DeletedRowState();
}

class _DeletedRowState extends ConsumerState<_DeletedRow> {
  bool _busy = false;

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      await ref.read(dataRepositoryProvider).restorePost(widget.post.id);
      ref.invalidate(deletedPostsProvider);
      ref.read(feedRevisionProvider.notifier).bump();
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.isReply)
            Text(
              'Reply',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (p.body.isNotEmpty) Text(p.body),
          if (p.media.isNotEmpty) ...[
            const SizedBox(height: 8),
            PostMediaView(media: p.media),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Deletes for good ${_relativeDays(p.purgesAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              _busy
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton(
                      onPressed: _restore,
                      child: const Text('Restore'),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}

String _relativeDays(DateTime when) {
  final days = when.difference(DateTime.now()).inDays;
  if (days <= 0) return 'soon';
  if (days == 1) return 'tomorrow';
  return 'in $days days';
}
