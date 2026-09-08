import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// An audience bucket owned by the account. "Public" is just a circle.
class Circle {
  const Circle({
    required this.id,
    required this.name,
    required this.slug,
    required this.isPublic,
    required this.sortOrder,
  });

  final String id;
  final String name;
  final String slug;
  final bool isPublic;
  final int sortOrder;

  factory Circle.fromMap(Map<String, dynamic> m) => Circle(
    id: m['id'] as String,
    name: m['name'] as String,
    slug: m['slug'] as String,
    isPublic: (m['is_public'] as bool?) ?? false,
    sortOrder: (m['sort_order'] as int?) ?? 0,
  );
}

class CircleRepository {
  CircleRepository(this._db);
  final SupabaseClient _db;

  Future<List<Circle>> myCircles() async {
    final rows = await _db.from('circle').select().order('sort_order');
    return (rows as List)
        .map((e) => Circle.fromMap(e as Map<String, dynamic>))
        .toList();
  }
}

final circleRepositoryProvider = Provider<CircleRepository>((ref) {
  return CircleRepository(ref.watch(supabaseProvider));
});

final myCirclesProvider = FutureProvider<List<Circle>>((ref) async {
  return ref.watch(circleRepositoryProvider).myCircles();
});
