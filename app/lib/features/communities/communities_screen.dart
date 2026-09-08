import 'package:flutter/material.dart';

import '../home/pillar_placeholder.dart';

class CommunitiesScreen extends StatelessWidget {
  const CommunitiesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PillarPlaceholder(
      title: 'Communities',
      icon: Icons.groups_outlined,
      phase: 'Phase 4',
      blurb:
          'Topic spaces with their own feed, chat channels, events, and a '
          'wiki. Transparent mod logs. Labels instead of silent removals.',
    );
  }
}
