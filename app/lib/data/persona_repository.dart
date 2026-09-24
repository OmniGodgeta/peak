import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

class Persona {
  const Persona({
    required this.id,
    required this.label,
    required this.isDefault,
  });

  final String id;
  final String label;
  final bool isDefault;

  factory Persona.fromMap(Map<String, dynamic> m) => Persona(
    id: m['id'] as String,
    label: m['label'] as String,
    isDefault: (m['is_default'] as bool?) ?? false,
  );
}

class PersonaRepository {
  PersonaRepository(this._db);
  final SupabaseClient _db;

  Future<List<Persona>> mine() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _db
        .from('persona')
        .select('id, label, is_default')
        .eq('account_id', uid)
        .order('created_at');
    return [
      for (final row in rows as List)
        Persona.fromMap(row as Map<String, dynamic>),
    ];
  }

  Future<void> create(String label) async {
    await _db.rpc('create_persona', params: {'p_label': label.trim()});
  }

  Future<void> makeDefault(String id) async {
    await _db.rpc('set_default_persona', params: {'p_id': id});
  }
}

final personaRepositoryProvider = Provider<PersonaRepository>((ref) {
  return PersonaRepository(ref.watch(supabaseProvider));
});

final myPersonasProvider = FutureProvider<List<Persona>>((ref) async {
  return ref.watch(personaRepositoryProvider).mine();
});
