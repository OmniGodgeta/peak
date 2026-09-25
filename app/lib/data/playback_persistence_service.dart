import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A simple service to persist small key-value pairs (like playback position) 
/// locally on the device across app restarts.
class PlaybackPersistenceService {
  const PlaybackPersistenceService(this._storage);
  final FlutterSecureStorage _storage;

  static const _prefix = 'playback_pos_';

  Future<void> savePosition(String postId, Duration position) async {
    await _storage.write(key: '$_prefix$postId', value: '${position.inMilliseconds}');
  }

  Future<Duration?> getPosition(String postId) async {
    final val = await _storage.read(key: '$_prefix$postId');
    if (val == null) return null;
    return Duration(milliseconds: int.parse(val));
  }

  Future<void> clearPosition(String postId) async {
    await _storage.delete(key: '$_prefix$postId');
  }
}

final playbackPersistenceServiceProvider = Provider<PlaybackPersistenceService>((ref) {
  return PlaybackPersistenceService(const FlutterSecureStorage());
});