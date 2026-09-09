import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/messaging_repository.dart';
import '../../data/people_repository.dart';
import 'chat_screen.dart';

/// Pick one or more people. With one → open a 1:1. With several → name a group
/// and create it. When [pickOnly] is set, pops with the selected list instead
/// (used by "Add people" in group settings).
class NewConversationScreen extends ConsumerStatefulWidget {
  const NewConversationScreen({super.key, this.pickOnly = false});
  final bool pickOnly;

  @override
  ConsumerState<NewConversationScreen> createState() =>
      _NewConversationScreenState();
}

class _NewConversationScreenState extends ConsumerState<NewConversationScreen> {
  final _search = TextEditingController();
  String _query = '';
  final _selected = <PersonSummary>[];
  final _title = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    _title.dispose();
    super.dispose();
  }

  bool _isSelected(PersonSummary p) => _selected.any((s) => s.id == p.id);

  Future<void> _go() async {
    if (_selected.isEmpty) return;
    if (widget.pickOnly) {
      Navigator.of(context).pop(_selected);
      return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(messagingRepositoryProvider);
      final String convId;
      final String title;
      if (_selected.length == 1) {
        convId = await repo.startDm(_selected.first.id);
        title = _selected.first.name;
      } else {
        convId = await repo.createGroup(
          _title.text.trim(),
          _selected.map((s) => s.id).toList(),
        );
        title = _title.text.trim().isEmpty ? 'Group' : _title.text.trim();
      }
      ref.read(conversationsRevisionProvider.notifier).bump();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(
            conversationId: convId,
            title: title,
            isGroup: _selected.length > 1,
          ),
        ),
      );
    } on Exception catch (e) {
      setState(() => _busy = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _query.trim().length >= 2
        ? ref.watch(peopleSearchProvider(_query.trim()))
        : null;
    final isGroup = _selected.length > 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickOnly ? 'Add people' : 'New message'),
        actions: [
          TextButton(
            onPressed: _busy || _selected.isEmpty ? null : _go,
            child: Text(
              widget.pickOnly ? 'Add' : (isGroup ? 'Create' : 'Chat'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_selected.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final p in _selected)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Chip(
                        label: Text(p.name),
                        onDeleted: () => setState(
                          () => _selected.removeWhere((s) => s.id == p.id),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (isGroup && !widget.pickOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Group name (optional)',
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search people',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(
            child: switch (results) {
              null => const SizedBox(),
              _ => results.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
                data: (people) => ListView(
                  children: [
                    for (final p in people)
                      CheckboxListTile(
                        value: _isSelected(p),
                        title: Text(p.name),
                        subtitle: Text(p.fqHandle),
                        onChanged: (_) => setState(() {
                          if (_isSelected(p)) {
                            _selected.removeWhere((s) => s.id == p.id);
                          } else {
                            _selected.add(p);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            },
          ),
        ],
      ),
    );
  }
}
