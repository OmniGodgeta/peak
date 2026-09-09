import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/modmail_repository.dart';
import 'modmail_thread_screen.dart';

/// Bottom sheet to open a new modmail thread with a community's mod team.
/// Returns `true` if a thread was created.
Future<bool?> showStartModmailSheet(
  BuildContext context, {
  required String communityId,
  required String communityName,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _StartModmailSheet(
      communityId: communityId,
      communityName: communityName,
    ),
  );
}

class _StartModmailSheet extends ConsumerStatefulWidget {
  const _StartModmailSheet({
    required this.communityId,
    required this.communityName,
  });
  final String communityId;
  final String communityName;

  @override
  ConsumerState<_StartModmailSheet> createState() => _StartModmailSheetState();
}

class _StartModmailSheetState extends ConsumerState<_StartModmailSheet> {
  final _subject = TextEditingController();
  final _body = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final subject = _subject.text.trim();
    final body = _body.text.trim();
    if (subject.isEmpty || body.isEmpty) {
      setState(() => _error = 'A subject and a message are both needed.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await ref
          .read(modmailRepositoryProvider)
          .start(widget.communityId, subject, body);
      ref.invalidate(myModmailThreadsProvider);
      ref.invalidate(communityModmailThreadsProvider);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ModmailThreadScreen(
            thread: ModmailThread(
              id: id,
              subject: subject,
              isOpen: true,
              createdAt: DateTime.now(),
              lastMessageAt: DateTime.now(),
              messageCount: 1,
              lastSnippet: body,
              lastFromMod: false,
              communityName: widget.communityName,
            ),
            viewerIsMod: false,
          ),
        ),
      );
    } on Exception catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Message the moderators of ${widget.communityName}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Only you and the moderator team can see this thread.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _subject,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Subject',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _body,
            minLines: 3,
            maxLines: 8,
            maxLength: 4000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Message',
              alignLabelWithHint: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _busy ? null : _send,
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Send'),
            ),
          ),
        ],
      ),
    );
  }
}
