import 'package:flutter/material.dart';

import '../home/pillar_placeholder.dart';

class MessagingScreen extends StatelessWidget {
  const MessagingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PillarPlaceholder(
      title: 'Messages',
      icon: Icons.forum_outlined,
      phase: 'Phase 2 · Phase 2.5 for E2E',
      blurb:
          '1:1 and group chat, end-to-end encrypted by default (MLS). '
          'Disappearing messages, read receipts off by default, a request '
          'inbox for non-connections.',
    );
  }
}
