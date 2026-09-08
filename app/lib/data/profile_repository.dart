import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// A ShadowChat account. Mirrors the `profile` table.
class Profile {
  const Profile({
    required this.id,
    required this.handle,
    required this.displayName,
    required this.bio,
    required this.accountKind,
    required this.showFollowCounts,
  });

  final String id;
  final String handle;
  final String displayName;
  final String bio;
  final String accountKind; // 'adult' | 'teen'
  final bool showFollowCounts;

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
    id: m['id'] as String,
    handle: m['handle'] as String,
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

  /// Calls the `bootstrap_account` RPC: creates the profile, default persona,
  /// and the five system circles in one transaction.
  Future<Profile> bootstrap({
    required String handle,
    required String displayName,
    bool teen = false,
  }) async {
    final row = await _db.rpc(
      'bootstrap_account',
      params: {
        'p_handle': handle,
        'p_display_name': displayName,
        'p_kind': teen ? 'teen' : 'adult',
      },
    );
    // rpc returns the profile row (single-row setof)
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
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(supabaseProvider));
});

/// The signed-in user's profile, or null if they still need onboarding.
final myProfileProvider = FutureProvider<Profile?>((ref) async {
  ref.watch(authStateProvider); // refetch on auth change
  return ref.watch(profileRepositoryProvider).myProfile();
});
