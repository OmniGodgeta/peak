import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/report_repository.dart';

/// Bottom sheet to report a post / profile / community / message.
Future<void> showReportSheet(
  BuildContext context, {
  required String kind,
  required String subjectId,
  String? what,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ReportSheet(kind: kind, subjectId: subjectId, what: what),
  );
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.kind, required this.subjectId, this.what});
  final String kind;
  final String subjectId;
  final String? what;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  ReportReason? _reason;
  final _detail = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_reason == null || _busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(reportRepositoryProvider)
          .submit(
            kind: widget.kind,
            subjectId: widget.subjectId,
            reason: _reason!,
            detail: _detail.text.trim().isEmpty ? null : _detail.text.trim(),
          );
      ref.invalidate(myReportsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Report sent. Thanks — a moderator will look at it.'),
        ),
      );
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Report ${widget.what ?? "this ${widget.kind}"}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'What is wrong with it?',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            RadioGroup<ReportReason>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(
                children: [
                  for (final r in ReportReason.values)
                    RadioListTile<ReportReason>(
                      value: r,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(r.label),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _detail,
              minLines: 2,
              maxLines: 4,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Anything else? (optional)',
                alignLabelWithHint: true,
              ),
            ),
            if (_reason == ReportReason.csam)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'This goes straight to site staff. If a child is in immediate '
                  'danger, contact local authorities as well.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _reason == null || _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Send report'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
