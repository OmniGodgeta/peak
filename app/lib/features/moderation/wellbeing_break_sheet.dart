import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/wellbeing_provider.dart';

class WellbeingBreakSheet extends ConsumerWidget {
  const WellbeingBreakSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(wellbeingProvider);
    final settingsEnabled = ref.watch(wellbeingSettingsProvider);

    if (!settingsEnabled || status == WellbeingStatus.normal) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            status == WellbeingStatus.breakRequired 
                ? Icons.spa_outlined 
                : Icons.timer_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text(
            status == WellbeingStatus.breakRequired
                ? 'Time for a breather?'
                : 'Just a quick heads up',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            status == WellbeingStatus.breakRequired
                ? 'You've been active for a while. Taking a short break can help you stay focused and enjoy the experience more.'
                : 'You're on a roll! Just a reminder to stay mindful of your screen time.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    ref.read(wellbeingProvider.notifier).reset();
                    Navigator.pop(context);
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Dismiss'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    ref.read(wellbeingProvider.notifier).reset();
                    Navigator.pop(context);
                    // In a real app, this might launch a breathing exercise or a timer
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Take a Break'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
