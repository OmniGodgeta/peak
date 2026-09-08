import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/messaging_repository.dart';
import '../../data/supabase_providers.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.title,
    this.otherId,
    this.isRequest = false,
  });

  final String conversationId;
  final String title;
  final String? otherId;
  final bool isRequest;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final Stream<List<ChatMessage>> _stream;
  bool _accepted = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _accepted = !widget.isRequest;
    _stream = ref
        .read(messagingRepositoryProvider)
        .messageStream(widget.conversationId);
    // mark read shortly after opening
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(messagingRepositoryProvider).markRead(widget.conversationId);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(messagingRepositoryProvider)
          .send(widget.conversationId, text);
      _input.clear();
      ref.read(messagingRepositoryProvider).markRead(widget.conversationId);
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _accept() async {
    await ref
        .read(messagingRepositoryProvider)
        .acceptRequest(widget.conversationId);
    setState(() => _accepted = true);
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(currentUserProvider)?.id;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<ChatMessage>>(
              stream: _stream,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final messages = snap.data!;
                if (messages.isEmpty) {
                  return Center(
                    child: Text(
                      'Say hello.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scroll.hasClients) {
                    _scroll.jumpTo(_scroll.position.maxScrollExtent);
                  }
                });
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final m = messages[i];
                    final mine = m.senderId == myId;
                    return _Bubble(message: m, mine: mine);
                  },
                );
              },
            ),
          ),
          if (widget.isRequest && !_accepted)
            _RequestBar(onAccept: _accept)
          else
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: 'Message',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filled(
                      onPressed: _sending ? null : _send,
                      icon: const Icon(Icons.send, size: 18),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = mine ? scheme.primary : scheme.surfaceContainerHigh;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          message.isDeleted ? 'Message deleted' : message.body,
          style: TextStyle(
            color: fg,
            fontStyle: message.isDeleted ? FontStyle.italic : null,
          ),
        ),
      ),
    );
  }
}

class _RequestBar extends StatelessWidget {
  const _RequestBar({required this.onAccept});
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'This person isn’t in your circles. Accept to reply.',
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: onAccept, child: const Text('Accept')),
          ],
        ),
      ),
    );
  }
}
