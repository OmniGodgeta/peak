import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// How loudly a label shows on a post. `hide` blurs the post behind a
/// tap-to-reveal; `warn` shows a prominent chip; `info` is a quiet chip.
enum LabelSeverity {
  info,
  warn,
  hide;

  static LabelSeverity parse(String? s) => switch (s) {
    'hide' => LabelSeverity.hide,
    'warn' => LabelSeverity.warn,
    _ => LabelSeverity.info,
  };

  String get wire => name;
}

/// A labeler the current user owns or subscribes to.
class LabelerDef {
  const LabelerDef({
    required this.id,
    required this.name,
    required this.description,
    required this.isPublic,
    required this.owned,
    required this.subscribed,
    required this.labelCount,
    required this.appliedCount,
  });

  final String id;
  final String name;
  final String description;
  final bool isPublic;
  final bool owned;
  final bool subscribed;
  final int labelCount;
  final int appliedCount;

  factory LabelerDef.fromMap(Map<String, dynamic> m) => LabelerDef(
    id: m['id'] as String,
    name: m['name'] as String,
    description: (m['description'] as String?) ?? '',
    isPublic: (m['is_public'] as bool?) ?? true,
    owned: (m['owned'] as bool?) ?? false,
    subscribed: (m['subscribed'] as bool?) ?? false,
    labelCount: (m['label_count'] as num?)?.toInt() ?? 0,
    appliedCount: (m['applied_count'] as num?)?.toInt() ?? 0,
  );
}

/// One label a labeler can apply.
class LabelDef {
  const LabelDef({
    required this.key,
    required this.name,
    required this.severity,
  });

  final String key;
  final String name;
  final LabelSeverity severity;

  factory LabelDef.fromMap(Map<String, dynamic> m) => LabelDef(
    key: m['key'] as String,
    name: m['name'] as String,
    severity: LabelSeverity.parse(m['severity'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'severity': severity.wire,
  };
}

/// A public labeler in the directory.
class BrowsedLabeler {
  const BrowsedLabeler({
    required this.id,
    required this.name,
    required this.description,
    required this.ownerHandle,
    required this.subscriberCount,
    required this.subscribed,
  });

  final String id;
  final String name;
  final String description;
  final String ownerHandle;
  final int subscriberCount;
  final bool subscribed;

  factory BrowsedLabeler.fromMap(Map<String, dynamic> m) => BrowsedLabeler(
    id: m['id'] as String,
    name: m['name'] as String,
    description: (m['description'] as String?) ?? '',
    ownerHandle: (m['owner_handle'] as String?) ?? '',
    subscriberCount: (m['subscriber_count'] as num?)?.toInt() ?? 0,
    subscribed: (m['subscribed'] as bool?) ?? false,
  );
}

/// A label the viewer should see on a post, from a labeler they trust.
class PostLabel {
  const PostLabel({
    required this.postId,
    required this.labelerId,
    required this.labelerName,
    required this.labelKey,
    required this.labelName,
    required this.severity,
    required this.note,
  });

  final String postId;
  final String labelerId;
  final String labelerName;
  final String labelKey;
  final String labelName;
  final LabelSeverity severity;
  final String? note;

  factory PostLabel.fromMap(Map<String, dynamic> m) => PostLabel(
    postId: m['post_id'] as String,
    labelerId: m['labeler_id'] as String,
    labelerName: (m['labeler_name'] as String?) ?? '',
    labelKey: m['label_key'] as String,
    labelName: (m['label_name'] as String?) ?? '',
    severity: LabelSeverity.parse(m['severity'] as String?),
    note: m['note'] as String?,
  );
}

class LabelerRepository {
  LabelerRepository(this._db);
  final SupabaseClient _db;

  Future<List<LabelerDef>> mine() async {
    final rows = await _db.rpc('my_labelers') as List;
    return [
      for (final r in rows) LabelerDef.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<BrowsedLabeler>> browse({String query = ''}) async {
    final rows =
        await _db.rpc('labelers_browse', params: {'p_query': query}) as List;
    return [
      for (final r in rows) BrowsedLabeler.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<LabelDef>> labels(String labelerId) async {
    final rows = await _db.rpc(
      'labeler_labels',
      params: {'p_labeler_id': labelerId},
    ) as List;
    return [for (final r in rows) LabelDef.fromMap(r as Map<String, dynamic>)];
  }

  Future<String> create({
    required String name,
    String description = '',
    bool isPublic = true,
  }) async => await _db.rpc(
    'create_labeler',
    params: {
      'p_name': name,
      'p_description': description,
      'p_public': isPublic,
    },
  ) as String;

  Future<void> setLabels(String labelerId, List<LabelDef> labels) => _db.rpc(
    'set_labeler_labels',
    params: {
      'p_labeler_id': labelerId,
      'p_labels': [for (final l in labels) l.toJson()],
    },
  );

  Future<void> applyLabel({
    required String labelerId,
    required String postId,
    required String labelKey,
    String? note,
  }) => _db.rpc(
    'apply_content_label',
    params: {
      'p_labeler_id': labelerId,
      'p_post_id': postId,
      'p_label_key': labelKey,
      'p_note': note,
    },
  );

  Future<void> removeLabel({
    required String labelerId,
    required String postId,
  }) => _db.rpc(
    'remove_content_label',
    params: {'p_labeler_id': labelerId, 'p_post_id': postId},
  );

  Future<void> subscribe(String labelerId) =>
      _db.rpc('subscribe_labeler', params: {'p_labeler_id': labelerId});

  Future<void> unsubscribe(String labelerId) =>
      _db.rpc('unsubscribe_labeler', params: {'p_labeler_id': labelerId});

  Future<List<PostLabel>> labelsForPosts(List<String> postIds) async {
    if (postIds.isEmpty) return const [];
    final rows = await _db.rpc(
      'post_labels_for_me',
      params: {'p_post_ids': postIds},
    ) as List;
    return [for (final r in rows) PostLabel.fromMap(r as Map<String, dynamic>)];
  }
}

final labelerRepositoryProvider = Provider<LabelerRepository>((ref) {
  return LabelerRepository(ref.watch(supabaseProvider));
});

/// Bumped after any labeler mutation so screens and post cards re-fetch.
class LabelerRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final labelerRevisionProvider = NotifierProvider<LabelerRevision, int>(
  LabelerRevision.new,
);

final myLabelersProvider = FutureProvider<List<LabelerDef>>((ref) async {
  ref.watch(labelerRevisionProvider);
  return ref.watch(labelerRepositoryProvider).mine();
});

final labelersBrowseProvider =
    FutureProvider.family<List<BrowsedLabeler>, String>((ref, query) async {
      ref.watch(labelerRevisionProvider);
      return ref.watch(labelerRepositoryProvider).browse(query: query);
    });

final labelerLabelsProvider = FutureProvider.family<List<LabelDef>, String>((
  ref,
  labelerId,
) async {
  ref.watch(labelerRevisionProvider);
  return ref.watch(labelerRepositoryProvider).labels(labelerId);
});

/// The labels the viewer should see on a single post. Cheap and cached per id;
/// most posts return nothing.
final postLabelsProvider = FutureProvider.family<List<PostLabel>, String>((
  ref,
  postId,
) async {
  ref.watch(labelerRevisionProvider);
  return ref.watch(labelerRepositoryProvider).labelsForPosts([postId]);
});
