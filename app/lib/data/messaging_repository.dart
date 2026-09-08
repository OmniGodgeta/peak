import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// A row from `conversations_list` — one entry in the Messages tab.
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.isGroup,
    required this.title,
    required this.lastMessageAt,
    required this.state,
    required this.unreadCount,
    required this.lastMessageBody,
    required this.lastMessageSender,
    required this.otherId,
    required this.otherHandle,
    required this.otherDomain,
    required this.otherDisplayName,
  });

  final String id;
  final bool isGroup;
  final String? title;
  final DateTime lastMessageAt;
  final String state; // 'active' | 'request'
  final int unreadCount;
  final String? lastMessageBody;
  final String? lastMessageSender;
  final String? otherId;
  final String? otherHandle;
  final String? otherDomain;
  final String? otherDisplayName;

  bool get isRequest => state == 'request';

  String get displayTitle {
    if (isGroup) return title?.isNotEmpty == true ? title! : 'Group';
    final name = otherDisplayName?.isNotEmpty == true
        ? otherDisplayName!
        : (otherHandle ?? 'Conversation');
    return name;
  }

  String get subtitle => (lastMessageBody?.isNotEmpty == true)
      ? lastMessageBody!
      : 'No messages yet';

  factory ConversationSummary.fromMap(Map<String, dynamic> m) =>
      ConversationSummary(
        id: m['id'] as String,
        isGroup: (m['is_group'] as bool?) ?? false,
        title: m['title'] as String?,
        lastMessageAt: DateTime.parse(m['last_message_at'] as String),
        state: (m['my_state'] as String?) ?? 'active',
        unreadCount: (m['unread_count'] as num?)?.toInt() ?? 0,
        lastMessageBody: m['last_message_body'] as String?,
        lastMessageSender: m['last_message_sender'] as String?,
        otherId: m['other_id'] as String?,
        otherHandle: m['other_handle'] as String?,
        otherDomain: m['other_domain'] as String?,
        otherDisplayName: m['other_display_name'] as String?,
      );
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.body,
    required this.senderId,
    required this.senderHandle,
    required this.senderDisplayName,
    required this.createdAt,
    required this.editedAt,
    required this.deletedAt,
  });

  final String id;
  final String body;
  final String? senderId;
  final String? senderHandle;
  final String? senderDisplayName;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  String get senderName => senderDisplayName?.isNotEmpty == true
      ? senderDisplayName!
      : (senderHandle ?? 'Someone');

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
    id: m['id'] as String,
    body: (m['body'] as String?) ?? '',
    senderId: m['sender_id'] as String?,
    senderHandle: m['sender_handle'] as String?,
    senderDisplayName: m['sender_display_name'] as String?,
    createdAt: DateTime.parse(m['created_at'] as String),
    editedAt: m['edited_at'] == null
        ? null
        : DateTime.parse(m['edited_at'] as String),
    deletedAt: m['deleted_at'] == null
        ? null
        : DateTime.parse(m['deleted_at'] as String),
  );

  /// Realtime rows arrive without the joined sender fields.
  factory ChatMessage.fromRealtime(Map<String, dynamic> m) => ChatMessage(
    id: m['id'] as String,
    body: (m['body'] as String?) ?? '',
    senderId: m['sender_id'] as String?,
    senderHandle: null,
    senderDisplayName: null,
    createdAt: DateTime.parse(m['created_at'] as String),
    editedAt: m['edited_at'] == null
        ? null
        : DateTime.parse(m['edited_at'] as String),
    deletedAt: m['deleted_at'] == null
        ? null
        : DateTime.parse(m['deleted_at'] as String),
  );
}

class MessagingRepository {
  MessagingRepository(this._db);
  final SupabaseClient _db;

  Future<List<ConversationSummary>> conversations({
    bool includeRequests = true,
  }) async {
    final rows = await _db.rpc(
      'conversations_list',
      params: {'p_include_requests': includeRequests},
    );
    return (rows as List)
        .map((e) => ConversationSummary.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<String> startDm(String otherUserId) async {
    return await _db.rpc('start_dm', params: {'p_other': otherUserId})
        as String;
  }

  Future<List<ChatMessage>> messages(String conversationId) async {
    final rows = await _db.rpc(
      'messages_page',
      params: {'p_conversation': conversationId, 'p_limit': 60},
    );
    return (rows as List)
        .map((e) => ChatMessage.fromMap(e as Map<String, dynamic>))
        .toList()
        .reversed
        .toList(); // oldest first for the chat view
  }

  Future<void> send(String conversationId, String body) async {
    await _db.from('message').insert({
      'conversation_id': conversationId,
      'sender_id': _db.auth.currentUser!.id,
      'body': body,
    });
  }

  Future<void> markRead(String conversationId) async {
    await _db.rpc(
      'mark_conversation_read',
      params: {'p_conversation': conversationId},
    );
  }

  Future<void> acceptRequest(String conversationId) async {
    await _db.rpc(
      'accept_message_request',
      params: {'p_conversation': conversationId},
    );
  }

  /// Live stream of messages in a conversation, oldest first.
  Stream<List<ChatMessage>> messageStream(String conversationId) {
    return _db
        .from('message')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at')
        .map((rows) => rows.map(ChatMessage.fromRealtime).toList());
  }
}

final messagingRepositoryProvider = Provider<MessagingRepository>((ref) {
  return MessagingRepository(ref.watch(supabaseProvider));
});

/// Bumped when a conversation changes so the list refreshes.
final conversationsRevisionProvider = NotifierProvider<_Rev, int>(_Rev.new);

class _Rev extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final conversationsProvider = FutureProvider<List<ConversationSummary>>((
  ref,
) async {
  ref.watch(conversationsRevisionProvider);
  return ref.watch(messagingRepositoryProvider).conversations();
});
