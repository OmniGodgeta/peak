import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/env.dart';
import 'supabase_providers.dart';

/// The result of storing one attachment: what goes into `post_media`.
class UploadedMedia {
  const UploadedMedia({
    required this.path,
    this.posterPath,
    this.width,
    this.height,
    this.durationMs,
  });

  /// Value for `post_media.storage_path` — a full URL when the media server
  /// handled it, or a bare bucket path for the Supabase fallback.
  final String path;
  final String? posterPath;
  final int? width;
  final int? height;
  final int? durationMs;
}

/// Stores post images + video. Prefers the self-hosted media server
/// ([Env.mediaBaseUrl]); falls back to Supabase Storage when it isn't
/// configured, so nothing breaks before the server is up.
class MediaService {
  MediaService(this._db);
  final SupabaseClient _db;

  bool get usingServer => Env.mediaServerConfigured;

  Future<UploadedMedia> uploadPostMedia({
    required Uint8List bytes,
    required String contentType,
    required bool isVideo,
  }) async {
    if (usingServer) return _uploadToServer(bytes, contentType);
    return _uploadToSupabase(bytes, contentType, isVideo);
  }

  /// A loadable URL for a value previously stored in `post_media.storage_path`
  /// or `poster_path`.
  String resolveUrl(String storagePath) {
    if (_isUrl(storagePath)) return storagePath;
    return _db.storage.from('post-media').getPublicUrl(storagePath);
  }

  Future<UploadedMedia> _uploadToServer(
    Uint8List bytes,
    String contentType,
  ) async {
    final token = _db.auth.currentSession?.accessToken;
    if (token == null) throw StateError('Not signed in.');
    final res = await http.post(
      Uri.parse('${Env.mediaBaseUrl}/upload'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': contentType},
      body: bytes,
    );
    if (res.statusCode != 200) {
      throw Exception(
        'Media upload failed (${res.statusCode}). '
        '${_briefError(res.body)}',
      );
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return UploadedMedia(
      path: j['url'] as String,
      posterPath: j['posterUrl'] as String?,
      width: (j['width'] as num?)?.toInt(),
      height: (j['height'] as num?)?.toInt(),
      durationMs: (j['durationMs'] as num?)?.toInt(),
    );
  }

  Future<UploadedMedia> _uploadToSupabase(
    Uint8List bytes,
    String contentType,
    bool isVideo,
  ) async {
    final uid = _db.auth.currentUser!.id;
    final path = '$uid/${const Uuid().v4()}.${_ext(contentType, isVideo)}';
    await _db.storage
        .from('post-media')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    return UploadedMedia(path: path);
  }

  static bool _isUrl(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

  static String _ext(String contentType, bool isVideo) => switch (contentType) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/avif' => 'avif',
    'video/quicktime' => 'mov',
    'video/webm' => 'webm',
    'video/mp4' => 'mp4',
    _ => isVideo ? 'mp4' : 'jpg',
  };

  static String _briefError(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is String) return j['error'] as String;
    } catch (_) {}
    return body.length > 120 ? body.substring(0, 120) : body;
  }
}

final mediaServiceProvider = Provider<MediaService>((ref) {
  return MediaService(ref.watch(supabaseProvider));
});
