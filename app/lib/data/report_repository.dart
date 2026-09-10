import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

enum ReportReason {
  spam('spam', 'Spam or scam'),
  harassment('harassment', 'Harassment or bullying'),
  hate('hate', 'Hate speech'),
  violence('violence', 'Violence or threats'),
  selfHarm('self_harm', 'Self-harm or suicide'),
  csam('csam', 'Child sexual abuse material'),
  nudity('nudity', 'Nudity or sexual content'),
  impersonation('impersonation', 'Impersonation'),
  misinformation('misinformation', 'Harmful misinformation'),
  other('other', 'Something else');

  const ReportReason(this.key, this.label);
  final String key;
  final String label;
}

class MyReport {
  const MyReport({
    required this.id,
    required this.subjectKind,
    required this.reason,
    required this.status,
    required this.createdAt,
    required this.resolution,
  });

  final String id;
  final String subjectKind;
  final String reason;
  final String status;
  final DateTime createdAt;
  final String? resolution;

  factory MyReport.fromMap(Map<String, dynamic> m) => MyReport(
    id: m['id'] as String,
    subjectKind: m['subject_kind'] as String,
    reason: m['reason'] as String,
    status: m['status'] as String,
    createdAt: DateTime.parse(m['created_at'] as String),
    resolution: m['resolution'] as String?,
  );
}

class QueueItem {
  const QueueItem({
    required this.id,
    required this.subjectKind,
    required this.subjectId,
    required this.communitySlug,
    required this.reason,
    required this.detail,
    required this.status,
    required this.isUrgent,
    required this.createdAt,
    required this.reporterHandle,
    required this.reportCount,
  });

  final String id;
  final String subjectKind;
  final String subjectId;
  final String? communitySlug;
  final String reason;
  final String? detail;
  final String status;
  final bool isUrgent;
  final DateTime createdAt;
  final String? reporterHandle;
  final int reportCount;

  factory QueueItem.fromMap(Map<String, dynamic> m) => QueueItem(
    id: m['id'] as String,
    subjectKind: m['subject_kind'] as String,
    subjectId: m['subject_id'] as String,
    communitySlug: m['community_slug'] as String?,
    reason: m['reason'] as String,
    detail: m['detail'] as String?,
    status: m['status'] as String,
    isUrgent: (m['is_urgent'] as bool?) ?? false,
    createdAt: DateTime.parse(m['created_at'] as String),
    reporterHandle: m['reporter_handle'] as String?,
    reportCount: (m['report_count'] as int?) ?? 1,
  );
}

class ReportRepository {
  ReportRepository(this._db);
  final SupabaseClient _db;

  Future<bool> amIStaff() async =>
      await _db.rpc('am_i_staff') as bool? ?? false;

  Future<void> submit({
    required String kind,
    required String subjectId,
    required ReportReason reason,
    String? detail,
  }) => _db.rpc(
    'submit_report',
    params: {
      'p_kind': kind,
      'p_subject_id': subjectId,
      'p_reason': reason.key,
      'p_detail': detail,
    },
  );

  Future<List<MyReport>> mine() async {
    final rows = await _db.rpc('my_reports') as List;
    return [for (final r in rows) MyReport.fromMap(r as Map<String, dynamic>)];
  }

  Future<List<QueueItem>> queue({String status = 'open'}) async {
    final rows =
        await _db.rpc('review_queue', params: {'p_status': status}) as List;
    return [for (final r in rows) QueueItem.fromMap(r as Map<String, dynamic>)];
  }

  Future<void> resolve(String id, String status, {String? resolution}) =>
      _db.rpc(
        'resolve_report',
        params: {
          'p_report_id': id,
          'p_status': status,
          'p_resolution': resolution,
        },
      );
}

final reportRepositoryProvider = Provider<ReportRepository>((ref) {
  return ReportRepository(ref.watch(supabaseProvider));
});

final amIStaffProvider = FutureProvider<bool>((ref) async {
  return ref.watch(reportRepositoryProvider).amIStaff();
});

final myReportsProvider = FutureProvider<List<MyReport>>((ref) async {
  return ref.watch(reportRepositoryProvider).mine();
});

final reviewQueueProvider = FutureProvider.family<List<QueueItem>, String>((
  ref,
  status,
) async {
  return ref.watch(reportRepositoryProvider).queue(status: status);
});
