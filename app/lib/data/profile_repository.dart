import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// A Peak account. Mirrors the `profile` table.
class Profile {
  const Profile({
    required this.id,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.bio,
    required this.accountKind,
    required this.showFollowCounts,
  });

  final String id;
  final String handle;
  final String domain;
  final String displayName;
  final String bio;
  final String accountKind; // 'adult' | 'teen'
  final bool showFollowCounts;

  /// Federation-shaped handle, shown everywhere: `@name@peak.social`.
  String get fqHandle => '@$handle@$domain';

  bool get isTeen => accountKind == 'teen';

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
    id: m['id'] as String,
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    bio: (m['bio'] as String?) ?? '',
    accountKind: (m['account_kind'] as String?) ?? 'adult',
    showFollowCounts: (m['show_follow_counts'] as bool?) ?? false,
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
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(supabaseProvider));
});

/// The signed-in user's profile, or null if they still need onboarding.
final myProfileProvider = FutureProvider<Profile?>((ref) async {
  ref.watch(authStateProvider); // refetch on auth change
  return ref.watch(profileRepositoryProvider).myProfile();
});
