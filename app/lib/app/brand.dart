import 'package:flutter/material.dart';

/// The Peak mark + wordmark, for splash / sign-in / empty states.
class PeakLogo extends StatelessWidget {
  const PeakLogo({super.key, this.size = 96, this.showTagline = true});

  final double size;
  final bool showTagline;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/brand/peak-icon.png',
          width: size,
          height: size,
          semanticLabel: 'Peak',
        ),
        const SizedBox(height: 12),
        Text(
          'Peak',
          style: text.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 4,
          ),
        ),
        if (showTagline) ...[
          const SizedBox(height: 2),
          Text(
            'HIGHER TOGETHER',
            style: text.labelSmall?.copyWith(
              letterSpacing: 3,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }
}
