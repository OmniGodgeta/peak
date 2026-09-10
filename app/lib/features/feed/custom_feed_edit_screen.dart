import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/community_repository.dart';
import '../../data/custom_feed_repository.dart';

class CustomFeedEditScreen extends ConsumerStatefulWidget {
  const CustomFeedEditScreen({super.key, this.existing});
  final CustomFeed? existing;

  @override
  ConsumerState<CustomFeedEditScreen> createState() =>
      _CustomFeedEditScreenState();
}

class _CustomFeedEditScreenState extends ConsumerState<CustomFeedEditScreen> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _any = TextEditingController(
    text: widget.existing?.rules.anyWords.join(', ') ?? '',
  );
  late final _not = TextEditingController(
    text: widget.existing?.rules.notWords.join(', ') ?? '',
  );
  late bool _onlyMedia = widget.existing?.rules.onlyMedia ?? false;
  late bool _public = widget.existing?.isPublic ?? false;
  late final Set<String> _communities = {
    ...?widget.existing?.rules.communities,
  };
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _any.dispose();
    _not.dispose();
    super.dispose();
  }

  List<String> _words(String s) => s
      .split(RegExp(r'[,\n]+'))
      .map((w) => w.trim())
      .where((w) => w.isNotEmpty)
      .toList();

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give the feed a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rules = FeedRules(
        communities: _communities.toList(),
        from: widget.existing?.rules.from ?? const [],
        anyWords: _words(_any.text),
        notWords: _words(_not.text),
        onlyMedia: _onlyMedia,
      );
      await ref
          .read(customFeedRepositoryProvider)
          .save(
            id: widget.existing?.id,
            name: _name.text.trim(),
            rules: rules,
            isPublic: _public,
          );
      ref.invalidate(myCustomFeedsProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myComms = ref.watch(myCommunitiesProvider).asData?.value ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New feed' : 'Edit feed'),
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
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Name',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _any,
            decoration: const InputDecoration(
              labelText: 'Include posts with any of these words',
              helperText:
                  'Comma-separated. Leave blank for "people you follow".',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _not,
            decoration: const InputDecoration(
              labelText: 'Exclude posts with any of these words',
              helperText: 'Comma-separated',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Only posts with photos or media'),
            value: _onlyMedia,
            onChanged: (v) => setState(() => _onlyMedia = v),
          ),
          if (myComms.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Communities', style: Theme.of(context).textTheme.labelLarge),
            Wrap(
              spacing: 6,
              children: [
                for (final c in myComms)
                  FilterChip(
                    label: Text(c.name),
                    selected: _communities.contains(c.id),
                    onSelected: (v) => setState(() {
                      if (v) {
                        _communities.add(c.id);
                      } else {
                        _communities.remove(c.id);
                      }
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Public'),
            subtitle: const Text('Anyone with the link can view and copy it'),
            value: _public,
            onChanged: (v) => setState(() => _public = v),
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
