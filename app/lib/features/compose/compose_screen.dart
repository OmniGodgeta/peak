import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/circle_repository.dart';
import '../../data/feed_repository.dart';
import '../../data/post_repository.dart';

/// Phase 1 composer: text + a mandatory circle picker + optional content
/// warning. Media, polls, reply/quote controls, drafts and scheduling come
/// later in Phase 1+ (see docs/PRODUCT.md §2.5).
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({super.key});

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _body = TextEditingController();
  final _cw = TextEditingController();
  final _selected = <String>{};
  bool _showCw = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _body.dispose();
    _cw.dispose();
    super.dispose();
  }

  Future<void> _post(List<Circle> circles) async {
    if (_body.text.trim().isEmpty) {
      setState(() => _error = 'Say something first.');
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = 'Pick at least one circle to post to.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final publicIds = circles
          .where((c) => c.isPublic)
          .map((c) => c.id)
          .toSet();
      final onlyPublic =
          _selected.length == 1 && publicIds.contains(_selected.first);
      await ref
          .read(postRepositoryProvider)
          .createPost(
            body: _body.text.trim(),
            visibility: onlyPublic
                ? PostVisibility.public
                : PostVisibility.circles,
            circleIds: _selected.toList(),
            contentWarning: _showCw && _cw.text.trim().isNotEmpty
                ? _cw.text.trim()
                : null,
          );
      ref.invalidate(feedProvider);
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final circlesAsync = ref.watch(myCirclesProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('New post'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () => _post(circlesAsync.asData?.value ?? const []),
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Post'),
            ),
          ),
        ],
      ),
      body: circlesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (circles) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_showCw) ...[
              TextField(
                controller: _cw,
                decoration: const InputDecoration(
                  labelText: 'Content warning',
                  hintText: 'Shown before the post; reader taps to reveal',
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _body,
              autofocus: true,
              minLines: 4,
              maxLines: 12,
              maxLength: 5000,
              decoration: const InputDecoration(hintText: "What's happening?"),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => _showCw = !_showCw),
                  icon: const Icon(Icons.warning_amber_outlined, size: 18),
                  label: Text(_showCw ? 'Remove warning' : 'Content warning'),
                ),
              ],
            ),
            const Divider(height: 24),
            Text(
              'Who can see this?',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in circles)
                  FilterChip(
                    label: Text(c.name),
                    avatar: Icon(
                      c.isPublic ? Icons.public : Icons.lock_outline,
                      size: 16,
                    ),
                    selected: _selected.contains(c.id),
                    onSelected: (on) => setState(() {
                      if (on) {
                        _selected.add(c.id);
                      } else {
                        _selected.remove(c.id);
                      }
                    }),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}
