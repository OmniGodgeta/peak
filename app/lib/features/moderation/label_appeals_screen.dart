import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/labeler_repository.dart';

/// Appeals on labels, plus a 90-day count that names nobody.
class LabelAppealsScreen extends ConsumerWidget {
  const LabelAppealsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(labelTransparencyProvider);
    final mine = ref.watch(myContentLabelsProvider);
    final queue = ref.watch(labelerAppealQueueProvider);
    final repo = ref.read(labelerRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Label appeals')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'If a labeler marked your post, you can ask them to look again. '
              'They should answer within 7 days. Upholding an appeal takes the label off.',
            ),
          ),
          counts.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ListTile(title: Text('$e')),
            data: (c) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Last 90 days: ${c.labelsApplied} labels, '
                '${c.appealsOpened} appeals, ${c.appealsUpheld} upheld, '
                '${c.appealsRejected} rejected. ${c.appealsOpen} still open.',
              ),
            ),
          ),
          const ListTile(
            title: Text('Labels on your posts', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          mine.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ListTile(title: Text('$e')),
            data: (rows) {
              if (rows.isEmpty) {
                return const ListTile(title: Text('No labels on your posts.'));
              }
              return Column(
                children: [
                  for (final row in rows)
                    ListTile(
                      title: Text(row.labelName),
                      subtitle: Text(
                        '${row.labelerName}'
                        '${row.appealStatus == null ? '' : ' · appeal ${row.appealStatus}'}',
                      ),
                      trailing: row.appealStatus == null || row.appealStatus == 'open'
                          ? TextButton(
                              onPressed: () => _file(context, ref, repo, row),
                              child: Text(row.appealStatus == 'open' ? 'Update' : 'Appeal'),
                            )
                          : null,
                    ),
                ],
              );
            },
          ),
          const ListTile(
            title: Text('Queue for your labelers', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          queue.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ListTile(title: Text('$e')),
            data: (rows) {
              if (rows.isEmpty) {
                return const ListTile(title: Text('No open appeals.'));
              }
              return Column(
                children: [
                  for (final row in rows)
                    ListTile(
                      title: Text(row.reason),
                      subtitle: Text(row.labelerName),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _resolve(ref, repo, row.id, 'upheld'),
                            child: const Text('Uphold'),
                          ),
                          TextButton(
                            onPressed: () => _resolve(ref, repo, row.id, 'rejected'),
                            child: const Text('Reject'),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _file(
    BuildContext context,
    WidgetRef ref,
    LabelerRepository repo,
    ContentLabelOnMine row,
  ) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ask for another look'),
        content: TextField(
          controller: reason,
          maxLength: 500,
          decoration: const InputDecoration(hintText: 'Why should this label come off?'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Send')),
        ],
      ),
    );
    final text = reason.text.trim();
    reason.dispose();
    if (ok != true || text.isEmpty || !context.mounted) return;
    await repo.fileAppeal(
      labelerId: row.labelerId,
      postId: row.postId,
      reason: text,
    );
    ref.read(labelerRevisionProvider.notifier).bump();
  }

  Future<void> _resolve(
    WidgetRef ref,
    LabelerRepository repo,
    String appealId,
    String status,
  ) async {
    await repo.resolveAppeal(appealId: appealId, status: status);
    ref.read(labelerRevisionProvider.notifier).bump();
  }
}
