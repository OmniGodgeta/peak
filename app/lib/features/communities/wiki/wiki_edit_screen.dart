import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/community_repository.dart';
import '../../../data/wiki_repository.dart';

/// Create or edit a wiki page. The slug is fixed once the page exists.
class WikiEditScreen extends ConsumerStatefulWidget {
  const WikiEditScreen({super.key, required this.community, this.existing});
  final Community community;
  final WikiPage? existing;

  @override
  ConsumerState<WikiEditScreen> createState() => _WikiEditScreenState();
}

class _WikiEditScreenState extends ConsumerState<WikiEditScreen> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _slug = TextEditingController(text: widget.existing?.slug ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? '');
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _title.dispose();
    _slug.dispose();
    _body.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    var slug = _slug.text.trim().toLowerCase();
    if (_isNew && slug.isEmpty) {
      slug = title
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
    }
    if (title.isEmpty || slug.isEmpty) {
      setState(() => _error = 'A title (and slug) are needed.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(wikiRepositoryProvider)
          .save(
            communityId: widget.community.id,
            slug: slug,
            title: title,
            body: _body.text,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      ref.invalidate(communityWikiPagesProvider(widget.community.id));
      ref.invalidate(wikiPageProvider((widget.community.id, slug)));
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New wiki page' : 'Edit page'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            maxLength: 140,
            decoration: const InputDecoration(
              labelText: 'Title',
              counterText: '',
            ),
          ),
          if (_isNew)
            TextField(
              controller: _slug,
              decoration: const InputDecoration(
                labelText: 'Slug (optional — derived from the title)',
                helperText: 'lower-case, letters/numbers/-',
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _body,
            minLines: 12,
            maxLines: null,
            maxLength: 50000,
            decoration: const InputDecoration(
              labelText: 'Body (Markdown: # headings, - lists)',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            maxLength: 280,
            decoration: const InputDecoration(
              labelText: 'Edit summary (optional)',
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
