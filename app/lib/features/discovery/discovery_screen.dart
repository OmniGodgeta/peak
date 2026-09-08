import 'package:flutter/material.dart';

import '../home/pillar_placeholder.dart';

class DiscoveryScreen extends StatelessWidget {
  const DiscoveryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PillarPlaceholder(
      title: 'Discover',
      icon: Icons.explore_outlined,
      phase: 'Phase 5',
      blurb:
          'Custom feeds, interests you pick (not tracking), a local tab for '
          'events and nearby communities, and search. Recommendations always '
          'explain themselves.',
    );
  }
}
