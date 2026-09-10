import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'wellbeing.dart';

/// Applies the greyscale filter (always-on setting or during quiet hours).
class WellbeingScope extends ConsumerWidget {
  const WellbeingScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grey = ref.watch(wellbeingProvider.select((w) => w.greyscaleActive));
    if (!grey) return child;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        0.2126, 0.7152, 0.0722, 0, 0, //
        0.2126, 0.7152, 0.0722, 0, 0,
        0.2126, 0.7152, 0.0722, 0, 0,
        0, 0, 0, 1, 0,
      ]),
      child: child,
    );
  }
}

/// Watches the session clock and shows a one-time "take a break" sheet once the
/// configured minute threshold is crossed. Mount once, inside HomeShell.
class BreakReminder extends ConsumerStatefulWidget {
  const BreakReminder({super.key});

  @override
  ConsumerState<BreakReminder> createState() => _BreakReminderState();
}

class _BreakReminderState extends ConsumerState<BreakReminder> {
  int _lastShownAt = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(sessionClockProvider, (_, minutes) {
      final threshold = ref.read(wellbeingProvider).breakAfterMinutes;
      if (threshold <= 0) return;
      if (minutes >= threshold && minutes - _lastShownAt >= threshold) {
        _lastShownAt = minutes;
        _showSheet(minutes);
      }
    });
    return const SizedBox.shrink();
  }

  void _showSheet(int minutes) {
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You have been on Peak for $minutes minutes.',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'No streaks, no penalty for leaving. The feed will be here later.',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      ref.read(sessionClockProvider.notifier).reset();
                      _lastShownAt = 0;
                      Navigator.pop(ctx);
                    },
                    child: const Text("I'll take a break"),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Keep going'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
