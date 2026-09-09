import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/community_repository.dart';

/// Admin-only edit form for a community's settings.
class CommunityEditScreen extends ConsumerStatefulWidget {
  const CommunityEditScreen({super.key, required this.community});
  final Community community;

  @override
  ConsumerState<CommunityEditScreen> createState() =>
      _CommunityEditScreenState();
}

class _CommunityEditScreenState extends ConsumerState<CommunityEditScreen> {
  late final _name = TextEditingController(text: widget.community.name);
  late final _description = TextEditingController(
    text: widget.community.description,
  );
  late final _topics = TextEditingController(
    text: widget.community.topics.join(', '),
  );
  late CommunityJoinPolicy _policy = widget.community.joinPolicy;
  late bool _nsfw = widget.community.isNsfw;
  late bool _listed = widget.community.isListed;
  final _rules = <(TextEditingController, TextEditingController)>[];
  bool _rulesLoaded = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(communityRepositoryProvider).rules(widget.community.id).then((
      list,
    ) {
      if (!mounted) return;
      setState(() {
        for (final r in list) {
          _rules.add((
            TextEditingController(text: r.title),
            TextEditingController(text: r.body),
          ));
        }
        _rulesLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _topics.dispose();
    for (final (t, b) in _rules) {
      t.dispose();
      b.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final topics = _topics.text
          .split(RegExp(r'[,\s]+'))
          .map((t) => t.trim().toLowerCase())
          .where((t) => t.isNotEmpty)
          .toList();
      await ref
          .read(communityRepositoryProvider)
          .saveSettings(
            communityId: widget.community.id,
            name: _name.text.trim(),
            description: _description.text.trim(),
            topics: topics,
            joinPolicy: _policy,
            nsfw: _nsfw,
            listed: _listed,
          );
      if (_rulesLoaded) {
        await ref.read(communityRepositoryProvider).setRules(
          widget.community.id,
          [
            for (final (t, b) in _rules)
              CommunityRule(title: t.text, body: b.text),
          ],
        );
        ref.invalidate(communityRulesProvider(widget.community.id));
      }
      ref.invalidate(communityViewProvider(widget.community.slug));
      ref.invalidate(communitiesBrowseProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit community'),
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
          Text(
            'c/${widget.community.slug}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          TextField(
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: _description,
            maxLength: 2000,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          TextField(
            controller: _topics,
            decoration: const InputDecoration(
              labelText: 'Topics',
              helperText: 'Comma-separated',
            ),
          ),
          const SizedBox(height: 16),
          Text('Who can join', style: Theme.of(context).textTheme.labelLarge),
          RadioGroup<CommunityJoinPolicy>(
            groupValue: _policy,
            onChanged: (v) => setState(() => _policy = v ?? _policy),
            child: const Column(
              children: [
                RadioListTile<CommunityJoinPolicy>(
                  value: CommunityJoinPolicy.open,
                  title: Text('Anyone'),
                ),
                RadioListTile<CommunityJoinPolicy>(
                  value: CommunityJoinPolicy.request,
                  title: Text('By request'),
                ),
                RadioListTile<CommunityJoinPolicy>(
                  value: CommunityJoinPolicy.invite,
                  title: Text('Invite only'),
                ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Listed in the directory'),
            value: _listed,
            onChanged: (v) => setState(() => _listed = v),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Rules', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              if (_rulesLoaded)
                TextButton.icon(
                  onPressed: () => setState(
                    () => _rules.add((
                      TextEditingController(),
                      TextEditingController(),
                    )),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add rule'),
                ),
            ],
          ),
          if (!_rulesLoaded)
            const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            ),
          for (var i = 0; i < _rules.length; i++)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _rules[i].$1,
                            decoration: InputDecoration(
                              hintText: 'Rule ${i + 1}',
                              isDense: true,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() {
                            final (t, b) = _rules.removeAt(i);
                            t.dispose();
                            b.dispose();
                          }),
                        ),
                      ],
                    ),
                    TextField(
                      controller: _rules[i].$2,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        hintText: 'Details (optional)',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('18+ / not safe for work'),
            value: _nsfw,
            onChanged: (v) => setState(() => _nsfw = v),
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
