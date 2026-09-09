import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/community_repository.dart';

class CreateCommunityScreen extends ConsumerStatefulWidget {
  const CreateCommunityScreen({super.key});

  @override
  ConsumerState<CreateCommunityScreen> createState() =>
      _CreateCommunityScreenState();
}

class _CreateCommunityScreenState extends ConsumerState<CreateCommunityScreen> {
  final _name = TextEditingController();
  final _slug = TextEditingController();
  final _description = TextEditingController();
  final _topics = TextEditingController();
  CommunityJoinPolicy _policy = CommunityJoinPolicy.open;
  bool _nsfw = false;
  bool _busy = false;
  String? _error;
  bool _slugEdited = false;

  @override
  void dispose() {
    _name.dispose();
    _slug.dispose();
    _description.dispose();
    _topics.dispose();
    super.dispose();
  }

  String _slugify(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '')
      .replaceAll(RegExp(r'-{2,}'), '-');

  Future<void> _create() async {
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
      final slug = await ref
          .read(communityRepositoryProvider)
          .create(
            slug: _slug.text.trim(),
            name: _name.text.trim(),
            description: _description.text.trim(),
            topics: topics,
            joinPolicy: _policy,
            nsfw: _nsfw,
          );
      ref.invalidate(myCommunitiesProvider);
      if (mounted) {
        Navigator.of(context)
            .pop(_slug.text.trim().isEmpty ? slug : _slug.text.trim());
      }
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        _name.text.trim().length >= 2 && _slug.text.trim().length >= 2;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New community'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy || !valid ? null : _create,
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create'),
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
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (v) => setState(() {
              if (!_slugEdited) _slug.text = _slugify(v);
            }),
          ),
          TextField(
            controller: _slug,
            maxLength: 32,
            decoration: const InputDecoration(
              labelText: 'Address',
              prefixText: 'peak.social/c/',
              helperText: 'Lowercase letters, numbers, - and _',
            ),
            onChanged: (v) => setState(() => _slugEdited = true),
          ),
          TextField(
            controller: _description,
            maxLength: 2000,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'What it’s about'),
          ),
          TextField(
            controller: _topics,
            decoration: const InputDecoration(
              labelText: 'Topics',
              helperText: 'Comma-separated, e.g. photography, film',
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
                  subtitle: Text('Open — join with one tap'),
                ),
                RadioListTile<CommunityJoinPolicy>(
                  value: CommunityJoinPolicy.request,
                  title: Text('By request'),
                  subtitle: Text('A moderator approves each join'),
                ),
                RadioListTile<CommunityJoinPolicy>(
                  value: CommunityJoinPolicy.invite,
                  title: Text('Invite only'),
                  subtitle: Text('Hidden from the directory'),
                ),
              ],
            ),
          ),
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
