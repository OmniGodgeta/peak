import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// Proof-of-personhood for one account — a "real person" signal, not identity
/// verification. `method` is 'staff' or 'vouch'; needs 3 vouches to auto-grant.
class Personhood {
  const Personhood({
    required this.verified,
    required this.method,
    required this.vouchCount,
    required this.iVouched,
  });

  final bool verified;
  final String? method;
  final int vouchCount;
  final bool iVouched;

  static const empty = Personhood(
    verified: false,
    method: null,
    vouchCount: 0,
    iVouched: false,
  );

  factory Personhood.fromMap(Map<String, dynamic> m) => Personhood(
    verified: (m['verified'] as bool?) ?? false,
    method: m['method'] as String?,
    vouchCount: (m['vouch_count'] as num?)?.toInt() ?? 0,
    iVouched: (m['i_vouched'] as bool?) ?? false,
  );
}

class VouchedPerson {
  const VouchedPerson({
    required this.handle,
    required this.displayName,
    required this.verified,
  });
  final String handle;
  final String displayName;
  final bool verified;

  factory VouchedPerson.fromMap(Map<String, dynamic> m) => VouchedPerson(
    handle: m['handle'] as String,
    displayName: (m['display_name'] as String?) ?? '',
    verified: (m['verified'] as bool?) ?? false,
  );
}

class PendingPerson {
  const PendingPerson({
    required this.handle,
    required this.displayName,
    required this.vouchCount,
  });
  final String handle;
  final String displayName;
  final int vouchCount;

  factory PendingPerson.fromMap(Map<String, dynamic> m) => PendingPerson(
    handle: m['handle'] as String,
    displayName: (m['display_name'] as String?) ?? '',
    vouchCount: (m['vouch_count'] as num?)?.toInt() ?? 0,
  );
}

class PersonhoodRepository {
  PersonhoodRepository(this._db);
  final SupabaseClient _db;

  Future<Personhood> of(String handle) async {
    final rows =
        await _db.rpc('personhood_of', params: {'p_handle': handle}) as List;
    return rows.isEmpty
        ? Personhood.empty
        : Personhood.fromMap(rows.first as Map<String, dynamic>);
  }

  Future<void> vouch(String handle) =>
      _db.rpc('vouch_for', params: {'p_handle': handle});

  Future<void> unvouch(String handle) =>
      _db.rpc('unvouch', params: {'p_handle': handle});

  Future<List<VouchedPerson>> myVouches() async {
    final rows = await _db.rpc('my_vouches') as List;
    return [
      for (final r in rows) VouchedPerson.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<void> grant(String handle) =>
      _db.rpc('grant_personhood', params: {'p_handle': handle});

  Future<void> revoke(String handle) =>
      _db.rpc('revoke_personhood', params: {'p_handle': handle});

  Future<List<PendingPerson>> pending() async {
    final rows = await _db.rpc('personhood_pending') as List;
    return [
      for (final r in rows) PendingPerson.fromMap(r as Map<String, dynamic>),
    ];
  }
}

final personhoodRepositoryProvider = Provider<PersonhoodRepository>((ref) {
  return PersonhoodRepository(ref.watch(supabaseProvider));
});

class PersonhoodRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final personhoodRevisionProvider = NotifierProvider<PersonhoodRevision, int>(
  PersonhoodRevision.new,
);

final personhoodOfProvider = FutureProvider.family<Personhood, String>((
  ref,
  handle,
) async {
  ref.watch(personhoodRevisionProvider);
  return ref.watch(personhoodRepositoryProvider).of(handle);
});

final myVouchesProvider = FutureProvider<List<VouchedPerson>>((ref) async {
  ref.watch(personhoodRevisionProvider);
  return ref.watch(personhoodRepositoryProvider).myVouches();
});

final personhoodPendingProvider = FutureProvider<List<PendingPerson>>((
  ref,
) async {
  ref.watch(personhoodRevisionProvider);
  return ref.watch(personhoodRepositoryProvider).pending();
});
