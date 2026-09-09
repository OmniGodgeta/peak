import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'supabase_providers.dart';

class ProfileLink {
  const ProfileLink({required this.label, required this.url});
  final String label;
  final String url;

  Map<String, String> toJson() => {'label': label, 'url': url};
  factory ProfileLink.fromJson(Map<String, dynamic> m) => ProfileLink(
    label: (m['label'] as String?) ?? '',
    url: (m['url'] as String?) ?? '',
  );
}

/// A Peak account. Mirrors the `profile` table.
class Profile {
  const Profile({
    required this.id,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.bio,
    required this.pronouns,
    required this.locationCoarse,
    required this.avatarPath,
    required this.links,
    required this.accountKind,
    required this.showFollowCounts,
    required this.isDiscoverable,
    required this.deletionRequestedAt,
  });

  final String id;
  final String handle;
  final String domain;
  final String displayName;
  final String bio;
  final String? pronouns;
  final String? locationCoarse;
  final String? avatarPath;
  final List<ProfileLink> links;
  final String accountKind; // 'adult' | 'teen'
  final bool showFollowCounts;
  final bool isDiscoverable;

  /// Set once the owner has asked to delete the account; the account is purged
  /// 30 days after this. While set, the app is locked to the closing screen.
  final DateTime? deletionRequestedAt;

  DateTime? get deletionPurgeAt =>
      deletionRequestedAt?.add(const Duration(days: 30));

  /// Federation-shaped handle, shown everywhere: `@name@peak.social`.
  String get fqHandle => '@$handle@$domain';

  bool get isTeen => accountKind == 'teen';
  String get displayNameOrHandle =>
      displayName.isNotEmpty ? displayName : handle;

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
    id: m['id'] as String,
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    bio: (m['bio'] as String?) ?? '',
    pronouns: m['pronouns'] as String?,
    locationCoarse: m['location_coarse'] as String?,
    avatarPath: m['avatar_path'] as String?,
    links: [
      for (final e in (m['links'] as List? ?? const []))
        ProfileLink.fromJson(e as Map<String, dynamic>),
    ],
    accountKind: (m['account_kind'] as String?) ?? 'adult',
    showFollowCounts: (m['show_follow_counts'] as bool?) ?? false,
    isDiscoverable: (m['is_discoverable'] as bool?) ?? true,
    deletionRequestedAt: m['deletion_requested_at'] == null
        ? null
        : DateTime.parse(m['deletion_requested_at'] as String),
  );
}

class ProfileRepository {
  ProfileRepository(this._db);
  final SupabaseClient _db;

  Future<Profile?> myProfile() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await _db.from('profile').select().eq('id', uid).maybeSingle();
    return row == null ? null : Profile.fromMap(row);
  }

  /// Calls the `bootstrap_account` RPC: creates the profile + private row
  /// (date of birth), default persona, and the five system circles in one
  /// transaction. The server enforces the 13+ floor and derives teen status.
  Future<Profile> bootstrap({
    required String handle,
    required String displayName,
    required DateTime birthdate,
  }) async {
    final row = await _db.rpc(
      'bootstrap_account',
      params: {
        'p_handle': handle,
        'p_display_name': displayName,
        'p_birthdate': isoDate(birthdate),
      },
    );
    final map = row is List
        ? row.first as Map<String, dynamic>
        : row as Map<String, dynamic>;
    return Profile.fromMap(map);
  }

  Future<bool> handleAvailable(String handle) async {
    final hit = await _db
        .from('profile')
        .select('id')
        .eq('handle', handle)
        .maybeSingle();
    return hit == null;
  }

  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Public URL for an `avatars` storage object.
  String avatarUrl(String path) =>
      _db.storage.from('avatars').getPublicUrl(path);

  Future<String> uploadAvatar(Uint8List bytes, String mime) async {
    final uid = _db.auth.currentUser!.id;
    final ext = switch (mime) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'jpg',
    };
    final path = '$uid/${const Uuid().v4()}.$ext';
    await _db.storage
        .from('avatars')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
    return path;
  }

  Future<void> updateProfile({
    required String displayName,
    required String bio,
    String? pronouns,
    String? locationCoarse,
    String? avatarPath,
    List<ProfileLink> links = const [],
    bool? showFollowCounts,
    bool? isDiscoverable,
  }) async {
    final uid = _db.auth.currentUser!.id;
    await _db
        .from('profile')
        .update({
          'display_name': displayName.trim(),
          'bio': bio.trim(),
          'pronouns': (pronouns ?? '').trim().isEmpty ? null : pronouns!.trim(),
          'location_coarse': (locationCoarse ?? '').trim().isEmpty
              ? null
              : locationCoarse!.trim(),
          'avatar_path': ?avatarPath,
          'links': links
              .where((l) => l.url.trim().isNotEmpty)
              .map((l) => l.toJson())
              .toList(),
          'show_follow_counts': ?showFollowCounts,
          'is_discoverable': ?isDiscoverable,
        })
        .eq('id', uid);
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(supabaseProvider));
});

/// The signed-in user's profile, or null if they still need onboarding.
final myProfileProvider = FutureProvider<Profile?>((ref) async {
  ref.watch(authStateProvider); // refetch on auth change
  return ref.watch(profileRepositoryProvider).myProfile();
});
