import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// One modmail thread — a private conversation between a member and a
/// community's moderator team. The mod-queue rows also carry the member's
/// identity and their current standing in the community.
class ModmailThread {
  const ModmailThread({
    required this.id,
    required this.subject,
    required this.isOpen,
    required this.createdAt,
    required this.lastMessageAt,
    required this.messageCount,
    required this.lastSnippet,
    required this.lastFromMod,
    this.communityId,
    this.communitySlug,
    this.communityName,
    this.memberId,
    this.memberHandle,
    this.memberDomain,
    this.memberDisplayName,
    this.memberAvatarPath,
    this.memberState,
  });

  final String id;
  final String subject;
  final bool isOpen;
  final DateTime createdAt;
  final DateTime lastMessageAt;
  final int messageCount;
  final String? lastSnippet;
  final bool lastFromMod;

  // present on my_modmail_threads
  final String? communityId;
  final String? communitySlug;
  final String? communityName;

  // present on community_modmail_threads (the mod queue)
  final String? memberId;
  final String? memberHandle;
  final String? memberDomain;
  final String? memberDisplayName;
  final String? memberAvatarPath;
  final String? memberState; // active | request | banned

  String get memberName => (memberDisplayName?.isNotEmpty ?? false)
      ? memberDisplayName!
      : (memberHandle ?? 'someone');

  String get memberFqHandle =>
      '@${memberHandle ?? "?"}@${memberDomain ?? "peak.social"}';

  bool get awaitingModerator => isOpen && !lastFromMod;

  factory ModmailThread.fromMap(Map<String, dynamic> m) => ModmailThread(
    id: m['id'] as String,
    subject: m['subject'] as String,
    isOpen: (m['state'] as String?) != 'closed',
    createdAt: DateTime.parse(m['created_at'] as String),
    lastMessageAt: DateTime.parse(m['last_message_at'] as String),
    messageCount: (m['message_count'] as int?) ?? 0,
    lastSnippet: m['last_snippet'] as String?,
    lastFromMod: (m['last_from_mod'] as bool?) ?? false,
    communityId: m['community_id'] as String?,
    communitySlug: m['community_slug'] as String?,
    communityName: m['community_name'] as String?,
    memberId: m['member_id'] as String?,
    memberHandle: m['member_handle'] as String?,
    memberDomain: m['member_domain'] as String?,
    memberDisplayName: m['member_display_name'] as String?,
    memberAvatarPath: m['member_avatar_path'] as String?,
    memberState: m['member_state'] as String?,
  );
}

class ModmailMessage {
  const ModmailMessage({
    required this.id,
    required this.senderId,
    required this.senderHandle,
    required this.senderDisplayName,
    required this.senderAvatarPath,
    required this.fromMod,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String? senderId;
  final String? senderHandle;
  final String? senderDisplayName;
  final String? senderAvatarPath;
  final bool fromMod;
  final String body;
  final DateTime createdAt;

  String get senderName => (senderDisplayName?.isNotEmpty ?? false)
      ? senderDisplayName!
      : (senderHandle ?? 'unknown');

  factory ModmailMessage.fromMap(Map<String, dynamic> m) => ModmailMessage(
    id: m['id'] as String,
    senderId: m['sender_id'] as String?,
    senderHandle: m['sender_handle'] as String?,
    senderDisplayName: m['sender_display_name'] as String?,
    senderAvatarPath: m['sender_avatar_path'] as String?,
    fromMod: (m['from_mod'] as bool?) ?? false,
    body: m['body'] as String,
    createdAt: DateTime.parse(m['created_at'] as String),
  );
}

class ModmailRepository {
  ModmailRepository(this._db);
  final SupabaseClient _db;

  Future<List<ModmailThread>> myThreads() async {
    final rows = await _db.rpc('my_modmail_threads') as List;
    return [
      for (final r in rows) ModmailThread.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<ModmailThread>> communityThreads(
    String communityId, {
    String state = 'open',
  }) async {
    final rows = await _db.rpc(
      'community_modmail_threads',
      params: {'p_community_id': communityId, 'p_state': state},
    ) as List;
    return [
      for (final r in rows) ModmailThread.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<ModmailMessage>> messages(String threadId) async {
    final rows = await _db.rpc(
      'modmail_messages',
      params: {'p_thread_id': threadId},
    ) as List;
    return [
      for (final r in rows) ModmailMessage.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<String> start(String communityId, String subject, String body) async {
    return await _db.rpc(
      'start_modmail',
      params: {
        'p_community_id': communityId,
        'p_subject': subject,
        'p_body': body,
      },
    ) as String;
  }

  Future<void> reply(String threadId, String body) => _db.rpc(
    'modmail_reply',
    params: {'p_thread_id': threadId, 'p_body': body},
  );

  Future<void> setOpen(String threadId, bool open) => _db.rpc(
    'set_modmail_state',
    params: {'p_thread_id': threadId, 'p_open': open},
  );
}

final modmailRepositoryProvider = Provider<ModmailRepository>((ref) {
  return ModmailRepository(ref.watch(supabaseProvider));
});

final myModmailThreadsProvider = FutureProvider<List<ModmailThread>>((
  ref,
) async {
  return ref.watch(modmailRepositoryProvider).myThreads();
});

/// Mod queue for one community, keyed by `(communityId, state)` where state is
/// `open`, `closed`, or `all`.
final communityModmailThreadsProvider =
    FutureProvider.family<List<ModmailThread>, (String, String)>((
      ref,
      key,
    ) async {
      return ref
          .watch(modmailRepositoryProvider)
          .communityThreads(key.$1, state: key.$2);
    });

final modmailMessagesProvider =
    FutureProvider.family<List<ModmailMessage>, String>((ref, threadId) async {
      return ref.watch(modmailRepositoryProvider).messages(threadId);
    });
