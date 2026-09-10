import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/report_repository.dart';

class MyReportsScreen extends ConsumerWidget {
  const MyReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = ref.watch(myReportsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Your reports')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myReportsProvider),
        child: reports.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Text("You haven't reported anything."),
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = list[i];
                return ListTile(
                  title: Text('${_label(r.reason)} · ${r.subjectKind}'),
                  subtitle: Text(
                    r.resolution?.isNotEmpty == true
                        ? '${_status(r.status)} — ${r.resolution}'
                        : _status(r.status),
                  ),
                  trailing: Text(
                    '${r.createdAt.year}-'
                    '${r.createdAt.month.toString().padLeft(2, '0')}-'
                    '${r.createdAt.day.toString().padLeft(2, '0')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

String _label(String key) => ReportReason.values
    .firstWhere((r) => r.key == key, orElse: () => ReportReason.other)
    .label;

String _status(String s) => switch (s) {
  'open' => 'Open',
  'reviewing' => 'Under review',
  'actioned' => 'Actioned',
  'dismissed' => 'Reviewed — no action',
  _ => s,
};
