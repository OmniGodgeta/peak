import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

class PeakApp extends ConsumerWidget {
  const PeakApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Peak',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // Dark-first identity ("deep space"). A user-facing theme control lands
      // with the Phase 5 wellbeing suite.
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
