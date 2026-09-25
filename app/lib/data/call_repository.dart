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
