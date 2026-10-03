import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../crypto/e2ee_service.dart';
import '../crypto/noop_e2ee.dart';
import '../crypto/openmls_e2ee.dart';
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
    this.e2ee = false,
  });

  final String id;
  final bool isGroup;

  /// End-to-end encrypted (MLS): the server only has ciphertext.
  final bool e2ee;
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
      : (e2ee && lastMessageSender != null)
      ? 'Encrypted message'
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
        e2ee: (m['e2ee'] as bool?) ?? false,
      );
}

class ChatMedia {
  const ChatMedia({
    required this.kind,
    required this.storagePath,
    this.altText,
    this.width,
    this.height,
    this.mimeType,
  });
  final String kind;
  final String storagePath;
  final String? altText;
  final int? width;
  final int? height;
  final String? mimeType;

  factory ChatMedia.fromMap(Map<String, dynamic> m) => ChatMedia(
    kind: (m['kind'] as String?) ?? 'image',
    storagePath: m['storage_path'] as String,
    altText: m['alt_text'] as String?,
    width: (m['width'] as num?)?.toInt(),
    height: (m['height'] as num?)?.toInt(),
    mimeType: m['mime_type'] as String?,
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
    this.media = const [],
    this.ciphertext,
    this.encrypted = false,
    this.unreadable = false,
  });

  final String id;
  final String body;
  final String? senderId;
  final String? senderHandle;
  final String? senderDisplayName;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final List<ChatMedia> media;

  /// MLS ciphertext as stored (`\\x…`), for encrypted conversations.
  final String? ciphertext;
  final bool encrypted;

  /// Encrypted, and this device can't read it (it joined the chat later).
  final bool unreadable;

  ChatMessage withPlaintext(String? text) => ChatMessage(
    id: id,
    body: text ?? '',
    senderId: senderId,
    senderHandle: senderHandle,
    senderDisplayName: senderDisplayName,
    createdAt: createdAt,
    editedAt: editedAt,
    deletedAt: deletedAt,
    media: media,
    encrypted: true,
    unreadable: text == null,
  );

  bool get isDeleted => deletedAt != null;
  bool get isEdited => editedAt != null && !isDeleted;
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
    media: [
      for (final e in (m['media'] as List? ?? const []))
        ChatMedia.fromMap(e as Map<String, dynamic>),
    ],
    ciphertext: m['ciphertext'] as String?,
    encrypted: m['ciphertext'] != null,
  );
}

/// A member of a group, for the settings roster.
class ConversationMember {
  const ConversationMember({
    required this.id,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.isTeen,
  });
  final String id;
  final String handle;
  final String domain;
  final String displayName;
  final bool isTeen;

  String get name => displayName.isNotEmpty ? displayName : handle;
  String get fqHandle => '@$handle@$domain';

  factory ConversationMember.fromMap(Map<String, dynamic> m) =>
      ConversationMember(
        id: m['member_id'] as String,
        handle: m['handle'] as String,
        domain: (m['domain'] as String?) ?? 'peak.social',
        displayName: (m['display_name'] as String?) ?? '',
        isTeen: (m['is_teen'] as bool?) ?? false,
      );
}

class MessagingRepository {
  MessagingRepository(this._db, [this._e2ee = const NoopE2ee()]);
  final SupabaseClient _db;
  final E2eeService _e2ee;

  /// Whether a conversation is end-to-end encrypted.
  Future<bool> isEncrypted(String conversationId) async {
    final row = await _db
        .from('conversation')
        .select('e2ee')
        .eq('id', conversationId)
        .maybeSingle();
    return (row?['e2ee'] as bool?) ?? false;
  }

  /// Encrypt a conversation that was just created, if every member can take
  /// part (docs/ENCRYPTION.md, 2.5-3). Leaves existing and already-used
  /// conversations alone; any failure leaves it a normal conversation.
  Future<void> _maybeEncrypt(String conversationId, List<String> others) async {
    if (!_e2ee.available) return;
    try {
      if (await isEncrypted(conversationId)) return;
      final started = await _db
          .from('mls_group_state')
          .select('conversation_id')
          .eq('conversation_id', conversationId)
          .limit(1);
      if (started.isNotEmpty) return;
      final used = await _db
          .from('message')
          .select('id')
          .eq('conversation_id', conversationId)
          .limit(1);
      if (used.isNotEmpty) return;
      await _e2ee.setUpConversation(conversationId, others);
    } catch (_) {
      // Stays a transport-encrypted conversation; nothing claims E2EE.
    }
  }

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
    final id =
        await _db.rpc('start_dm', params: {'p_other': otherUserId}) as String;
    await _maybeEncrypt(id, [otherUserId]);
    return id;
  }

  /// Full message history for a conversation, oldest first (with media + sender
  /// names). Realtime changes trigger a re-fetch of this in the chat screen.
  Future<List<ChatMessage>> messages(String conversationId) async {
    final rows = await _db.rpc(
      'messages_page',
      params: {'p_conversation': conversationId, 'p_limit': 60},
    );
    final list = (rows as List)
        .map((e) => ChatMessage.fromMap(e as Map<String, dynamic>))
        .toList()
        .reversed
        .toList();
    // Encrypted chat: apply membership/device changes first (2.5-4).
    if (list.any((m) => m.ciphertext != null)) {
      try {
        await _e2ee.syncConversation(conversationId);
      } catch (_) {
        // Still show what's already cached / decryptable.
      }
    }
    // Oldest first: MLS decrypts in order, and each message only once (the
    // E2EE layer caches the result).
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.ciphertext == null || m.isDeleted) continue;
      list[i] = m.withPlaintext(
        await _e2ee.readMessage(
          conversationId,
          m.id,
          OpenMlsE2ee.bytea(m.ciphertext!),
        ),
      );
    }
    return list;
  }

  Future<void> send(
    String conversationId,
    String body, {
    List<({Uint8List bytes, String mime, String? alt})> media = const [],
    DateTime? expiresAt,
  }) async {
    final uid = _db.auth.currentUser!.id;
    if (await isEncrypted(conversationId)) {
      if (media.isNotEmpty) {
        throw StateError(
          'Attachments aren\'t supported in encrypted chats yet.',
        );
      }
      final enc = await _e2ee.encryptMessage(conversationId, body);
      final hex = enc.ciphertext
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join();
      final row = await _db
          .from('message')
          .insert({
            'conversation_id': conversationId,
            'sender_id': uid,
            'body': '',
            'ciphertext': '\\x$hex',
            'mls_epoch': enc.epoch,
            if (expiresAt != null) 'expires_at': expiresAt.toIso8601String(),
          })
          .select('id')
          .single();
      await _e2ee.rememberSent(row['id'] as String, body);
      return;
    }
    final msg = await _db
        .from('message')
        .insert({
          'conversation_id': conversationId,
          'sender_id': uid,
          'body': body,
          if (expiresAt != null) 'expires_at': expiresAt.toIso8601String(),
        })
        .select('id')
        .single();
    final messageId = msg['id'] as String;

    if (media.isEmpty) return;
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      final ext = switch (m.mime) {
        'audio/m4a' => 'm4a',
        'audio/aac' => 'aac',
        'image/png' => 'png',
        'image/gif' => 'gif',
        'image/webp' => 'webp',
        _ => 'jpg',
      };
      final path = '$conversationId/${const Uuid().v4()}.$ext';
      await _db.storage
          .from('message-media')
          .uploadBinary(
            path,
            m.bytes,
            fileOptions: FileOptions(contentType: m.mime),
          );
      rows.add({
        'message_id': messageId,
        'kind': m.mime.startsWith('audio/') ? 'audio' : 'image',
        'storage_path': path,
        'alt_text': (m.alt ?? '').trim().isEmpty ? null : m.alt!.trim(),
        'sort_order': i,
        'mime_type': m.mime,
      });
    }
    await _db.from('message_media').insert(rows);
  }

  Future<String> mediaSignedUrl(String storagePath) =>
      _db.storage.from('message-media').createSignedUrl(storagePath, 3600);

  Future<void> editMessage(String id, String body) =>
      _db.rpc('edit_message', params: {'p_id': id, 'p_body': body});

  Future<void> deleteMessage(String id) =>
      _db.rpc('delete_message', params: {'p_id': id});

  Future<void> markRead(String conversationId) => _db.rpc(
    'mark_conversation_read',
    params: {'p_conversation': conversationId},
  );

  Future<void> acceptRequest(String conversationId) => _db.rpc(
    'accept_message_request',
    params: {'p_conversation': conversationId},
  );

  // ── Groups ──────────────────────────────────────────────────────────────
  Future<String> createGroup(String title, List<String> memberIds) async {
    final id = await _db.rpc(
      'create_group',
      params: {'p_title': title, 'p_members': memberIds},
    ) as String;
    final me = _db.auth.currentUser!.id;
    await _maybeEncrypt(id, [
      for (final m in memberIds)
        if (m != me) m,
    ]);
    return id;
  }

  Future<void> addGroupMember(String conversationId, String userId) async {
    if (await isEncrypted(conversationId)) {
      // All their devices join the MLS group and they become a member in one
      // step (2.5-4).
      await _e2ee.addMember(conversationId, userId);
      return;
    }
    await _db.rpc(
      'add_group_member',
      params: {'p_conversation': conversationId, 'p_user': userId},
    );
  }

  Future<void> leaveConversation(String conversationId) =>
      _db.rpc('leave_conversation', params: {'p_conversation': conversationId});

  Future<List<ConversationMember>> members(String conversationId) async {
    final rows = await _db.rpc(
      'conversation_members',
      params: {'p_conversation': conversationId},
    );
    return (rows as List)
        .map((e) => ConversationMember.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  // ── Read receipts ───────────────────────────────────────────────────────
  Future<void> setShareReadReceipts(String conversationId, bool value) async {
    await _db
        .from('conversation_member')
        .update({'share_read_receipts': value})
        .eq('conversation_id', conversationId)
        .eq('member_id', _db.auth.currentUser!.id);
  }

  Future<void> setDisappearingMessages(String conversationId, bool enabled) =>
      _db.rpc(
        'set_disappearing_messages',
        params: {'p_conversation': conversationId, 'p_enabled': enabled},
      );

  Future<bool> isDisappearingEnabled(String conversationId) async {
    final row = await _db
        .from('conversation')
        .select('disappearing_enabled')
        .eq('id', conversationId)
        .single();
    return row['disappearing_enabled'] as bool? ?? false;
  }

  /// Other members' read positions — non-empty only when both sides opted in.
  Future<Map<String, DateTime>> readState(String conversationId) async {
    final rows = await _db.rpc(
      'conversation_read_state',
      params: {'p_conversation': conversationId},
    );
    return {
      for (final r in (rows as List))
        (r as Map)['member_id'] as String: DateTime.parse(
          r['last_read_at'] as String,
        ),
    };
  }

  /// A realtime channel for a conversation: postgres changes on `message` +
  /// broadcast for typing. Caller subscribes and disposes.
  RealtimeChannel conversationChannel(String conversationId) {
    return _db.channel('conv:$conversationId');
  }
}

final messagingRepositoryProvider = Provider<MessagingRepository>((ref) {
  return MessagingRepository(
    ref.watch(supabaseProvider),
    ref.watch(e2eeServiceProvider),
  );
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

/// Total unread across conversations — drives the Messages tab badge.
final unreadMessagesProvider = Provider<int>((ref) {
  final convos = ref.watch(conversationsProvider).asData?.value ?? const [];
  return convos.where((c) => !c.isRequest).fold(0, (n, c) => n + c.unreadCount);
});

/// Full message history for one conversation. The chat screen calls
/// `ref.invalidate(messagesProvider(id))` on each realtime change to refetch.
final messagesProvider = FutureProvider.family<List<ChatMessage>, String>((
  ref,
  conversationId,
) async {
  return ref.watch(messagingRepositoryProvider).messages(conversationId);
});
