import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// Reasons this person asked to see less of. This does not change rank.
class SeeLessStore {
  SeeLessStore(this._db);
  final SupabaseClient _db;

  Future<Set<String>> reasons() async {
    final me = _db.auth.currentUser?.id;
    if (me == null) return const {};
    final rows = await _db
        .from('feed_see_less')
        .select('reason')
        .eq('user_id', me);
    return {
      for (final row in rows as List)
        (row as Map)['reason'] as String,
    };
  }

  Future<void> remember(String reason) async {
    final me = _db.auth.currentUser?.id;
    final trimmed = reason.trim();
    if (me == null || trimmed.isEmpty) return;
    await _db.from('feed_see_less').upsert({
      'user_id': me,
      'reason': trimmed,
    });
  }
}

final seeLessStoreProvider = Provider<SeeLessStore>(
  (ref) => SeeLessStore(ref.watch(supabaseProvider)),
);
