import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

class LinkPreviewData {
  const LinkPreviewData({
    required this.url,
    required this.kind,
    this.finalUrl,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
    this.videoId,
    this.ok = true,
  });

  final String url;

  /// `link` | `video` (direct file) | `youtube` | `photo`
  final String kind;
  final String? finalUrl;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;
  final String? videoId;
  final bool ok;

  bool get isYoutube => kind == 'youtube' && videoId != null;
  bool get isDirectVideo => kind == 'video' && (finalUrl ?? url).isNotEmpty;
  bool get hasCard =>
      ok && (title != null || imageUrl != null || siteName != null);

  factory LinkPreviewData.fromMap(Map<String, dynamic> m) => LinkPreviewData(
    url: m['url'] as String,
    kind: (m['kind'] as String?) ?? 'link',
    finalUrl: m['final_url'] as String?,
    title: _clean(m['title'] as String?),
    description: _clean(m['description'] as String?),
    imageUrl: m['image_url'] as String?,
    siteName: _clean(m['site_name'] as String?),
    videoId: m['video_id'] as String?,
    ok: (m['ok'] as bool?) ?? true,
  );

  static String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}

class LinkPreviewRepository {
  LinkPreviewRepository(this._db);
  final SupabaseClient _db;

  /// Cache hit → read the row directly; miss/stale → ask the Edge Function to
  /// fetch + fill, then use its result.
  Future<LinkPreviewData?> get(String url) async {
    final row = await _db
        .from('link_preview')
        .select()
        .eq('url', url)
        .maybeSingle();
    if (row != null) {
      final fetched = DateTime.tryParse(row['fetched_at'] as String? ?? '');
      final fresh =
          fetched != null && DateTime.now().difference(fetched).inDays < 7;
      if (fresh) return LinkPreviewData.fromMap(row);
    }
    try {
      final res = await _db.functions.invoke(
        'link-preview',
        body: {'url': url},
      );
      final data = res.data;
      if (data is Map<String, dynamic>) return LinkPreviewData.fromMap(data);
    } on Exception {
      // fall through — a stale row is better than nothing
    }
    return row == null ? null : LinkPreviewData.fromMap(row);
  }
}

final linkPreviewRepositoryProvider = Provider<LinkPreviewRepository>((ref) {
  return LinkPreviewRepository(ref.watch(supabaseProvider));
});

final linkPreviewProvider = FutureProvider.family<LinkPreviewData?, String>((
  ref,
  url,
) async {
  return ref.watch(linkPreviewRepositoryProvider).get(url);
});

final _urlRe = RegExp(r'''https?://[^\s<>()"']+''');

/// Every http(s) URL in a block of text, in order (trailing punctuation trimmed).
List<String> urlsIn(String text) => _urlRe
    .allMatches(text)
    .map((m) => m.group(0)!.replaceAll(RegExp(r'[.,;:!?)\]]+$'), ''))
    .toList();

/// The URL worth previewing: the first video/YouTube link if any, else the
/// first link.
String? previewUrlFor(String text) {
  final urls = urlsIn(text);
  if (urls.isEmpty) return null;
  final video = urls.firstWhere(
    (u) => _looksVideo(u),
    orElse: () => urls.first,
  );
  return video;
}

bool _looksVideo(String u) {
  final l = u.toLowerCase();
  return l.contains('youtube.com/') ||
      l.contains('youtu.be/') ||
      l.contains('vimeo.com/') ||
      RegExp(r'\.(mp4|m4v|webm|mov|m3u8)(\?|$)').hasMatch(l);
}
