import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/modmail_repository.dart';

/// One modmail conversation. Shared by the member and the moderators — the
/// `viewerIsMod` flag only changes the framing (reply label, member standing).
class ModmailThreadScreen extends ConsumerStatefulWidget {
  const ModmailThreadScreen({
    super.key,
    required this.thread,
    required this.viewerIsMod,
  });

  final ModmailThread thread;
  final bool viewerIsMod;

  @override
  ConsumerState<ModmailThreadScreen> createState() =>
      _ModmailThreadScreenState();
}

class _ModmailThreadScreenState extends ConsumerState<ModmailThreadScreen> {
  final _controller = TextEditingController();
  late bool _open = widget.thread.isOpen;
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _invalidate() {
    ref.invalidate(modmailMessagesProvider(widget.thread.id));
    ref.invalidate(myModmailThreadsProvider);
    ref.invalidate(communityModmailThreadsProvider);
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(modmailRepositoryProvider).reply(widget.thread.id, text);
      _controller.clear();
      _invalidate();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleOpen() async {
    try {
      await ref
          .read(modmailRepositoryProvider)
          .setOpen(widget.thread.id, !_open);
      setState(() => _open = !_open);
      _invalidate();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(modmailMessagesProvider(widget.thread.id));
    final t = widget.thread;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.subject, style: const TextStyle(fontSize: 16)),
            Text(
              widget.viewerIsMod
                  ? '${t.memberName} · ${t.memberState ?? "?"}'
                  : (t.communityName ?? 'Moderators'),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _toggleOpen,
            child: Text(_open ? 'Close' : 'Reopen'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_open)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Text(
                'This thread is closed.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (list) => ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: list.length,
                itemBuilder: (_, i) =>
                    _Bubble(message: list[i], mine: _isMine(list[i])),
              ),
            ),
          ),
          if (_open)
            _Composer(
              controller: _controller,
              sending: _sending,
              onSend: _send,
              isMod: widget.viewerIsMod,
            ),
        ],
      ),
    );
  }

  bool _isMine(ModmailMessage m) {
    // A moderator's own view: their replies (from_mod) sit on the right.
    // The member's view: their replies (not from_mod) sit on the right.
    return widget.viewerIsMod ? m.fromMod : !m.fromMod;
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final ModmailMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final align = mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = mine
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              message.fromMod
                  ? '${message.senderName} · moderator'
                  : message.senderName,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 2),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(message.body),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.isMod,
  });
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final bool isMod;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: isMod
                      ? 'Reply as the moderator team'
                      : 'Message the moderators',
                  counterText: '',
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              icon: sending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              onPressed: sending ? null : onSend,
            ),
          ],
        ),
      ),
    );
  }
}
