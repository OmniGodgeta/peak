import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../wellbeing/wellbeing.dart';

class WellbeingScreen extends ConsumerWidget {
  const WellbeingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(wellbeingProvider);
    final notifier = ref.read(wellbeingProvider.notifier);
    final session = ref.watch(sessionClockProvider);

    String fmt(int? m) => m == null
        ? 'Not set'
        : TimeOfDay(hour: m ~/ 60, minute: m % 60).format(context);

    Future<int?> pick(int? current) async {
      final t = await showTimePicker(
        context: context,
        initialTime: current == null
            ? TimeOfDay.now()
            : TimeOfDay(hour: current ~/ 60, minute: current % 60),
      );
      return t == null ? null : t.hour * 60 + t.minute;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Wellbeing')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'This session: $session min. Settings stay on this device.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const _Header('Take a break'),
          RadioGroup<int>(
            groupValue: w.breakAfterMinutes,
            onChanged: (v) =>
                notifier.update(w.copyWith(breakAfterMinutes: v ?? 0)),
            child: const Column(
              children: [
                RadioListTile<int>(value: 0, title: Text('Off')),
                RadioListTile<int>(
                  value: 15,
                  title: Text('Remind me after 15 minutes'),
                ),
                RadioListTile<int>(value: 30, title: Text('After 30 minutes')),
                RadioListTile<int>(value: 60, title: Text('After 60 minutes')),
              ],
            ),
          ),
          const Divider(),
          const _Header('Greyscale'),
          SwitchListTile(
            title: const Text('Always greyscale'),
            subtitle: const Text('Colour is a pull. Turn it down.'),
            value: w.greyscaleAlways,
            onChanged: (v) => notifier.update(w.copyWith(greyscaleAlways: v)),
          ),
          const Divider(),
          const _Header('Quiet hours'),
          ListTile(
            title: const Text('Start'),
            trailing: Text(fmt(w.quietStartMin)),
            onTap: () async => notifier.update(
              w.copyWith(quietStartMin: await pick(w.quietStartMin)),
            ),
          ),
          ListTile(
            title: const Text('End'),
            trailing: Text(fmt(w.quietEndMin)),
            onTap: () async => notifier.update(
              w.copyWith(quietEndMin: await pick(w.quietEndMin)),
            ),
          ),
          SwitchListTile(
            title: const Text('Greyscale during quiet hours'),
            value: w.quietGreyscale,
            onChanged: w.hasQuietHours
                ? (v) => notifier.update(w.copyWith(quietGreyscale: v))
                : null,
          ),
          SwitchListTile(
            title: const Text('Hide like / reply counts during quiet hours'),
            value: w.quietHideCounts,
            onChanged: w.hasQuietHours
                ? (v) => notifier.update(w.copyWith(quietHideCounts: v))
                : null,
          ),
          if (w.hasQuietHours && (w.quietStartMin != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextButton(
                onPressed: () => notifier.update(
                  w.copyWith(quietStartMin: null, quietEndMin: null),
                ),
                child: const Text('Clear quiet hours'),
              ),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}
