import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// A local audio call. Signaling (SDP offer/answer + ICE candidates) rides
/// on a Supabase Realtime broadcast channel per room - the same mechanism
/// `MessagingRepository.conversationChannel` already uses for typing
/// indicators - rather than standing up a dedicated signaling server.
///
/// Room membership lives in `call_rooms`/`call_participants`
/// (`supabase/migrations/20261008210000_calls_and_rooms.sql`), which already
/// existed but was never wired to anything real.
class CallRepository {
  CallRepository(this._db);
  final SupabaseClient _db;

  String get _myId => _db.auth.currentUser!.id;

  /// Creates a new private 1:1 call room and returns its id. The creator is
  /// always the "offerer" once someone else joins - see CallRoomScreen for
  /// why a fixed role avoids two peers racing to send offers at once.
  Future<String> createRoom({String? title}) async {
    final row = await _db
        .from('call_rooms')
        .insert({
          'owner_id': _myId,
          'title': title,
          'is_public': false,
          'max_participants': 2,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  Future<void> joinRoom(String roomId) async {
    await _db.from('call_participants').upsert(
      {
        'room_id': roomId,
        'user_id': _myId,
        'left_at': null,
      },
      onConflict: 'room_id,user_id',
    );
  }

  Future<void> leaveRoom(String roomId) async {
    await _db
        .from('call_participants')
        .update({'left_at': DateTime.now().toUtc().toIso8601String()})
        .eq('room_id', roomId)
        .eq('user_id', _myId);
  }

  Future<String?> roomOwnerId(String roomId) async {
    final row = await _db
        .from('call_rooms')
        .select('owner_id')
        .eq('id', roomId)
        .maybeSingle();
    return row?['owner_id'] as String?;
  }

  /// Creates a live room tied to a Space (multi-party, up to
  /// `max_participants`). Unlike a 1:1 DM call room, anyone in the space can
  /// join without an explicit invite - `call_rooms`' existing "Space members
  /// can view space rooms" RLS policy already covers this.
  Future<String> createSpaceRoom({
    required String spaceId,
    String? title,
    int maxParticipants = 4,
  }) async {
    final row = await _db
        .from('call_rooms')
        .insert({
          'owner_id': _myId,
          'title': title,
          'is_public': false,
          'space_id': spaceId,
          'max_participants': maxParticipants,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  /// Rooms in a Space that currently have at least one active (not left)
  /// participant - the `list_active_space_rooms` RPC from
  /// `20261010000000_space_live_rooms.sql`.
  Future<List<SpaceLiveRoom>> activeRoomsForSpace(String spaceId) async {
    final rows = await _db.rpc(
      'list_active_space_rooms',
      params: {'p_space_id': spaceId},
    );
    return (rows as List)
        .map((e) => SpaceLiveRoom.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  /// The signaling channel for one call room. Caller subscribes to
  /// `onBroadcast` for the events it cares about, then calls `.subscribe()`
  /// itself (mirrors `MessagingRepository.conversationChannel`) and disposes
  /// it when the call ends.
  RealtimeChannel signalingChannel(String roomId) {
    return _db.channel('call:$roomId');
  }
}

final callRepositoryProvider = Provider<CallRepository>((ref) {
  return CallRepository(ref.watch(supabaseProvider));
});

class SpaceLiveRoom {
  final String id;
  final String? title;
  final String ownerId;
  final int participantCount;

  const SpaceLiveRoom({
    required this.id,
    required this.title,
    required this.ownerId,
    required this.participantCount,
  });

  factory SpaceLiveRoom.fromMap(Map<String, dynamic> m) => SpaceLiveRoom(
        id: m['id'] as String,
        title: m['title'] as String?,
        ownerId: m['owner_id'] as String,
        participantCount: (m['participant_count'] as num).toInt(),
      );
}
