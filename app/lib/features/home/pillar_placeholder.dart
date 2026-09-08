import 'package:flutter/material.dart';

/// Shared "this pillar isn't built yet" screen. Each pillar has a real screen
/// scheduled — see docs/ROADMAP.md.
class PillarPlaceholder extends StatelessWidget {
  const PillarPlaceholder({
    super.key,
    required this.title,
    required this.icon,
    required this.phase,
    required this.blurb,
  });

  final String title;
  final IconData icon;
  final String phase;
  final String blurb;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(phase, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(blurb, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
