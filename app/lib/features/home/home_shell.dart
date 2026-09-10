import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../crypto/device_repository.dart';
import '../../updater/update_gate.dart';
import '../../wellbeing/wellbeing_gate.dart';

/// The four-pillar shell: Feed · Messages · Communities · Discover, plus Me.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.dynamic_feed_outlined),
      selectedIcon: Icon(Icons.dynamic_feed),
      label: 'Feed',
    ),
    NavigationDestination(
      icon: Icon(Icons.forum_outlined),
      selectedIcon: Icon(Icons.forum),
      label: 'Messages',
    ),
    NavigationDestination(
      icon: Icon(Icons.groups_outlined),
      selectedIcon: Icon(Icons.groups),
      label: 'Communities',
    ),
    NavigationDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: 'Discover',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: 'Me',
    ),
  ];
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  void initState() {
    super.initState();
    // Register this install (device identity + signature key) once we're past
    // auth + onboarding. Fire-and-forget: the Devices screen surfaces failures.
    Future.microtask(() => ref.read(myDevicesProvider.future).ignore());
  }

  @override
  Widget build(BuildContext context) {
    final shell = widget.shell;
    return WellbeingScope(
      child: Scaffold(
        body: Column(
          children: [
            const UpdateBanner(),
            const BreakReminder(),
            Expanded(child: shell),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          destinations: HomeShell._destinations,
          onDestinationSelected: (i) =>
              shell.goBranch(i, initialLocation: i == shell.currentIndex),
        ),
      ),
    );
  }
}
