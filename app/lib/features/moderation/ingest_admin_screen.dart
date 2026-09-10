import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/ingest_admin_repository.dart';

/// Staff-only. The mirror/news feeds (@webb, @playstation, @scinews, …):
/// see recent auto-posts, hide a bad one, and turn a source on/off.
class IngestAdminScreen extends ConsumerWidget {
  const IngestAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(ingestSourcesProvider);
    final recent = ref.watch(ingestRecentProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Auto-feeds')),
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.read(ingestAdminRevisionProvider.notifier).bump(),
        child: ListView(
          children: [
            const _Header('Sources'),
            sources.when(
              loading: () => const _Loading(),
              error: (e, _) => _Err('$e'),
              data: (list) => list.isEmpty
                  ? const _Empty("No sources have run yet.")
                  : Column(
                      children: [for (final s in list) _SourceTile(source: s)],
                    ),
            ),
            const Divider(height: 24),
            const _Header('Recent items'),
            recent.when(
              loading: () => const _Loading(),
              error: (e, _) => _Err('$e'),
              data: (list) => list.isEmpty
                  ? const _Empty('Nothing ingested yet.')
                  : Column(
                      children: [for (final it in list) _ItemTile(item: it)],
                    ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _SourceTile extends ConsumerWidget {
  const _SourceTile({required this.source});
  final IngestSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = source;
    final sub = <String>[
      '${s.liveTotal} live · ${s.seenTotal} seen',
      if (s.lastRunAt != null) 'ran ${_ago(s.lastRunAt!)}',
      if (s.note != null && s.note!.isNotEmpty) '⚠ ${s.note}',
    ].join(' · ');

    return SwitchListTile(
      title: Text('@${s.source}'),
      subtitle: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
      value: s.enabled,
      onChanged: (v) async {
        await ref.read(ingestAdminRepositoryProvider).setEnabled(s.source, v);
        ref.read(ingestAdminRevisionProvider.notifier).bump();
      },
    );
  }
}

class _ItemTile extends ConsumerStatefulWidget {
  const _ItemTile({required this.item});
  final IngestItem item;

  @override
  ConsumerState<_ItemTile> createState() => _ItemTileState();
}

class _ItemTileState extends ConsumerState<_ItemTile> {
  bool _busy = false;

  Future<void> _hide() async {
    final id = widget.item.postId;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(ingestAdminRepositoryProvider).hidePost(id);
      ref.read(ingestAdminRevisionProvider.notifier).bump();
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
    final it = widget.item;
    final scheme = Theme.of(context).colorScheme;
    final heading = it.title?.trim().isNotEmpty == true
        ? it.title!.trim()
        : (it.postBody ?? it.externalId).replaceAll('\n', ' ').trim();

    return ListTile(
      title: Text(
        heading.isEmpty ? '(no title)' : heading,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: it.postDeleted
            ? TextStyle(
                color: scheme.onSurfaceVariant,
                decoration: TextDecoration.lineThrough,
              )
            : null,
      ),
      subtitle: Text(
        '@${it.source}'
        '${it.communitySlug != null ? ' → c/${it.communitySlug}' : ''}'
        ' · ${_ago(it.seenAt)}',
      ),
      trailing: it.postDeleted
          ? const Text('Hidden')
          : it.postId == null
          ? null
          : (_busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(onPressed: _hide, child: const Text('Hide'))),
      onTap: it.url == null
          ? null
          : () => launchUrl(
              Uri.parse(it.url!),
              mode: LaunchMode.externalApplication,
            ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

class _Header extends StatelessWidget {
  const _Header(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
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
