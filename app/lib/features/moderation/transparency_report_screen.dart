import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/supabase_providers.dart';

/// A quarter, e.g. 2026 Q3.
typedef Quarter = ({int year, int quarter});

Quarter quarterOf(DateTime t) =>
    (year: t.year, quarter: (t.month - 1) ~/ 3 + 1);

Quarter previousQuarter(Quarter q) => q.quarter == 1
    ? (year: q.year - 1, quarter: 4)
    : (year: q.year, quarter: q.quarter - 1);

/// Formats a suppressed count: -1 means 1–4 (see the SQL function).
String formatReportCount(Object? n) {
  if (n == null) return '—';
  final v = (n as num).toInt();
  return v == -1 ? 'fewer than 5' : '$v';
}

final transparencyReportProvider =
    FutureProvider.family<Map<String, dynamic>, Quarter>((ref, q) async {
      final res = await ref.watch(supabaseProvider).rpc(
        'transparency_report',
        params: {'p_year': q.year, 'p_quarter': q.quarter},
      );
      return Map<String, dynamic>.from(res as Map);
    });

const _reasonLabels = {
  'spam': 'Spam',
  'harassment': 'Harassment',
  'hate': 'Hate',
  'violence': 'Violence',
  'self_harm': 'Self-harm',
  'csam': 'Child sexual abuse material',
  'nudity': 'Nudity',
  'impersonation': 'Impersonation',
  'misinformation': 'Misinformation',
  'other': 'Other',
};

const _statusLabels = {
  'open': 'Waiting',
  'reviewing': 'Being reviewed',
  'actioned': 'Action taken',
  'dismissed': 'No action needed',
};

const _modActionLabels = {
  'approve_request': 'Join requests approved',
  'decline_request': 'Join requests declined',
  'set_role': 'Role changes',
  'remove_member': 'Members removed',
  'ban_member': 'Members banned',
  'unban_member': 'Members unbanned',
  'label_post': 'Posts labelled',
  'unlabel_post': 'Labels removed',
  'remove_post': 'Posts removed',
  'edit_settings': 'Settings changed',
};

/// The instance's quarterly moderation numbers. Aggregates only; counts of
/// 1–4 are shown as "fewer than 5" so nobody can be picked out.
class TransparencyReportScreen extends ConsumerStatefulWidget {
  const TransparencyReportScreen({super.key});

  @override
  ConsumerState<TransparencyReportScreen> createState() =>
      _TransparencyReportScreenState();
}

class _TransparencyReportScreenState
    extends ConsumerState<TransparencyReportScreen> {
  late Quarter _q = quarterOf(DateTime.now().toUtc());

  // Peak's first quarter; nothing to report before it.
  static const Quarter _first = (year: 2026, quarter: 3);

  bool get _atFirst =>
      _q.year < _first.year ||
      (_q.year == _first.year && _q.quarter <= _first.quarter);

  bool get _atCurrent => _q == quarterOf(DateTime.now().toUtc());

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(transparencyReportProvider(_q));
    return Scaffold(
      appBar: AppBar(title: const Text('Transparency report')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Previous quarter',
                icon: const Icon(Icons.chevron_left),
                onPressed: _atFirst
                    ? null
                    : () => setState(() => _q = previousQuarter(_q)),
              ),
              Expanded(
                child: Text(
                  '${_q.year} · Q${_q.quarter}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Next quarter',
                icon: const Icon(Icons.chevron_right),
                onPressed: _atCurrent
                    ? null
                    : () => setState(
                        () => _q = _q.quarter == 4
                            ? (year: _q.year + 1, quarter: 1)
                            : (year: _q.year, quarter: _q.quarter + 1),
                      ),
              ),
            ],
          ),
          report.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text("Couldn't load the report: $e"),
            ),
            data: (r) => _ReportBody(report: r),
          ),
        ],
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report});
  final Map<String, dynamic> report;

  Map<String, dynamic> _m(Object? v) =>
      v == null ? const {} : Map<String, dynamic>.from(v as Map);

  @override
  Widget build(BuildContext context) {
    final period = _m(report['period']);
    final reports = _m(report['reports']);
    final appeals = _m(report['label_appeals']);
    final mod = _m(report['community_moderation']);
    final person = _m(report['personhood_granted']);
    final text = Theme.of(context).textTheme;
    final median = reports['median_hours_to_handle'];
    final appealMedian = appeals['median_hours_to_resolve'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (period['complete'] != true)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'This quarter is still running — numbers so far.',
              textAlign: TextAlign.center,
              style: text.bodySmall,
            ),
          ),
        Text(
          'Counts from 1 to 4 are shown as “fewer than 5” so no one can be '
          'identified from them. No names, posts or reports are shown here.',
          style: text.bodySmall,
        ),
        _Section(
          title: 'Reports',
          rows: [
            ('Total', formatReportCount(reports['total'])),
            ('Flagged urgent', formatReportCount(reports['urgent'])),
            (
              'Typical time to a decision',
              median == null ? 'not enough to say' : '$median hours',
            ),
          ],
        ),
        _Section(
          title: 'Reports by reason',
          rows: [
            for (final e in _reasonLabels.entries)
              (e.value, formatReportCount(_m(reports['by_reason'])[e.key])),
          ],
        ),
        _Section(
          title: 'What happened to them',
          rows: [
            for (final e in _statusLabels.entries)
              (e.value, formatReportCount(_m(reports['by_status'])[e.key])),
          ],
        ),
        _Section(
          title: 'Label appeals',
          rows: [
            ('Filed', formatReportCount(appeals['filed'])),
            ('Label removed', formatReportCount(appeals['upheld'])),
            ('Label kept', formatReportCount(appeals['rejected'])),
            ('Still open', formatReportCount(appeals['still_open'])),
            (
              'Typical time to a decision',
              appealMedian == null ? 'not enough to say' : '$appealMedian hours',
            ),
          ],
        ),
        _Section(
          title: 'Space moderators',
          rows: [
            for (final e in _modActionLabels.entries)
              (e.value, formatReportCount(mod[e.key])),
          ],
        ),
        _Section(
          title: 'Labels and verification',
          rows: [
            (
              'Labels applied by labelers',
              formatReportCount(report['labeler_labels_applied']),
            ),
            ('Verified by staff', formatReportCount(person['staff'])),
            ('Verified by vouches', formatReportCount(person['vouch'])),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});
  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(label)),
                    Text(
                      value,
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
