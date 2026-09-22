import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';
import '../core/wellbeing_provider.dart';
import '../features/moderation/wellbeing_break_sheet.dart';

class PeakApp extends ConsumerWidget {
  const PeakApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final wellbeingStatus = ref.watch(wellbeingProvider);

    return MaterialApp.router(
      title: 'Peak',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            if (wellbeingStatus != WellbeingStatus.normal)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: const WellbeingBreakSheet(),
              ),
          ],
        );
      },
    );
  }
}
