import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/messaging_repository.dart';
import '../../data/supabase_providers.dart';
import 'group_settings_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.title,
    this.otherId,
    this.isGroup = false,
    this.isRequest = false,
  });

  final String conversationId;
  final String title;
  final String? otherId;
  final bool isGroup;
  final bool isRequest;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _pending = <({Uint8List bytes, String mime})>[];
  RealtimeChannel? _channel;
  Timer? _typingStop;
  bool _accepted = false;
  bool _sending = false;
  final _typingNames = <String>{};
  Map<String, DateTime> _reads = const {};

  MessagingRepository get _repo => ref.read(messagingRepositoryProvider);
  String? get _myId => ref.read(currentUserProvider)?.id;

  @override
  void initState() {
    super.initState();
    _accepted = !widget.isRequest;
    _repo.markRead(widget.conversationId);
    _loadReads();
    _subscribe();
  }

  @override
  void dispose() {
    _typingStop?.cancel();
    _channel?.unsubscribe();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadReads() async {
    try {
      final r = await _repo.readState(widget.conversationId);
      if (mounted) setState(() => _reads = r);
    } on Exception {
      /* receipts optional */
    }
  }

  void _subscribe() {
    final ch = _repo.conversationChannel(widget.conversationId)
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'message',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'conversation_id',
          value: widget.conversationId,
        ),
        callback: (_) {
          ref.invalidate(messagesProvider(widget.conversationId));
          _repo.markRead(widget.conversationId);
          _loadReads();
        },
      )
      ..onBroadcast(
        event: 'typing',
        callback: (payload) {
          final name = payload['name'] as String?;
          final uid = payload['uid'] as String?;
          if (name == null || uid == _myId) return;
          setState(() => _typingNames.add(name));
          Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _typingNames.remove(name));
          });
        },
      );
    ch.subscribe();
    _channel = ch;
  }

  void _notifyTyping() {
    _channel?.sendBroadcastMessage(
      event: 'typing',
      payload: {'uid': _myId, 'name': 'Someone'},
    );
    _typingStop?.cancel();
    _typingStop = Timer(const Duration(seconds: 3), () {});
  }

  Future<void> _pickImages() async {
    final picked = await ImagePicker().pickMultiImage(limit: 4);
    for (final x in picked) {
      final bytes = await x.readAsBytes();
      _pending.add((bytes: bytes, mime: x.mimeType ?? 'image/jpeg'));
    }
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if ((text.isEmpty && _pending.isEmpty) || _sending) return;
    setState(() => _sending = true);
    try {
      await _repo.send(
        widget.conversationId,
        text,
        media: [
          for (final p in _pending) (bytes: p.bytes, mime: p.mime, alt: null),
        ],
      );
      _input.clear();
      _pending.clear();
      ref.invalidate(messagesProvider(widget.conversationId));
      _repo.markRead(widget.conversationId);
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
    await _repo.acceptRequest(widget.conversationId);
    setState(() => _accepted = true);
  }

  Future<void> _messageActions(ChatMessage m) async {
    if (m.senderId != _myId || m.isDeleted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for everyone'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'delete') {
      await _repo.deleteMessage(m.id);
      ref.invalidate(messagesProvider(widget.conversationId));
    } else if (action == 'edit') {
      final controller = TextEditingController(text: m.body);
      final newBody = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Edit message'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (newBody != null && newBody.isNotEmpty && newBody != m.body) {
        await _repo.editMessage(m.id, newBody);
        ref.invalidate(messagesProvider(widget.conversationId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(messagesProvider(widget.conversationId));
    final lastReadByOther = _reads.values.isEmpty
        ? null
        : _reads.values.reduce((a, b) => a.isAfter(b) ? a : b);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.isGroup)
            IconButton(
              icon: const Icon(Icons.group_outlined),
              tooltip: 'Members',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GroupSettingsScreen(
                    conversationId: widget.conversationId,
                    title: widget.title,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (list) {
                if (list.isEmpty) {
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
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final m = list[i];
                    final mine = m.senderId == _myId;
                    final seen =
                        mine &&
                        lastReadByOther != null &&
                        !lastReadByOther.isBefore(m.createdAt) &&
                        i == list.length - 1;
                    return GestureDetector(
                      onLongPress: () => _messageActions(m),
                      child: _Bubble(
                        message: m,
                        mine: mine,
                        showSender: widget.isGroup && !mine,
                        seen: seen,
                        signedUrl: _repo.mediaSignedUrl,
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_typingNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'typing…',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (widget.isRequest && !_accepted)
            _RequestBar(onAccept: _accept)
          else
            _Composer(
              controller: _input,
              pendingCount: _pending.length,
              sending: _sending,
              onPickImages: _pickImages,
              onSend: _send,
              onChanged: (_) => _notifyTyping(),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.pendingCount,
    required this.sending,
    required this.onPickImages,
    required this.onSend,
    required this.onChanged,
  });

  final TextEditingController controller;
  final int pendingCount;
  final bool sending;
  final VoidCallback onPickImages;
  final VoidCallback onSend;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            IconButton(
              icon: Badge(
                isLabelVisible: pendingCount > 0,
                label: Text('$pendingCount'),
                child: const Icon(Icons.image_outlined),
              ),
              onPressed: onPickImages,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                onChanged: onChanged,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Message',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: sending ? null : onSend,
              icon: const Icon(Icons.send, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.showSender,
    required this.seen,
    required this.signedUrl,
  });

  final ChatMessage message;
  final bool mine;
  final bool showSender;
  final bool seen;
  final Future<String> Function(String) signedUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = mine ? scheme.primary : scheme.surfaceContainerHigh;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSender && !message.isDeleted)
                  Text(
                    message.senderName,
                    style: TextStyle(
                      fontSize: 11,
                      color: fg.withValues(alpha: 0.8),
                    ),
                  ),
                for (final media in message.media)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: FutureBuilder<String>(
                        future: signedUrl(media.storagePath),
                        builder: (context, snap) => snap.hasData
                            ? Image.network(
                                snap.data!,
                                width: 220,
                                fit: BoxFit.cover,
                              )
                            : Container(
                                width: 220,
                                height: 160,
                                color: scheme.surfaceContainerHighest,
                              ),
                      ),
                    ),
                  ),
                if (message.isDeleted)
                  Text(
                    'Message deleted',
                    style: TextStyle(color: fg, fontStyle: FontStyle.italic),
                  )
                else if (message.body.isNotEmpty)
                  Text(message.body, style: TextStyle(color: fg)),
              ],
            ),
          ),
          if (message.isEdited || seen)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                [if (message.isEdited) 'edited', if (seen) 'seen'].join(' · '),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
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
