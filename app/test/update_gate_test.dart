import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peak/updater/update_gate.dart';
import 'package:peak/updater/update_service.dart';

const _release = AppRelease(
  versionName: '1.4.0',
  versionCode: 5,
  apkUrl: 'https://example.test/peak.apk',
  sha256: null,
  notes: 'Faster feed.',
  minSupportedVersionCode: 2,
);

Widget _host(Widget child, UpdateCheck check) => ProviderScope(
  overrides: [updateCheckProvider.overrideWith((ref) async => check)],
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  testWidgets('banner is hidden when up to date', (tester) async {
    await tester.pumpWidget(
      _host(
        const UpdateBanner(),
        const UpdateCheck(status: UpdateStatus.upToDate, currentVersionCode: 5),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('is available'), findsNothing);
  });

  testWidgets('banner shows and dismisses when an update is available', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const UpdateBanner(),
        const UpdateCheck(
          status: UpdateStatus.available,
          currentVersionCode: 3,
          release: _release,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Peak 1.4.0 is available'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.textContaining('is available'), findsNothing);
  });

  testWidgets('UpdateRequiredScreen renders the block', (tester) async {
    await tester.pumpWidget(
      _host(
        const UpdateRequiredScreen(),
        const UpdateCheck(
          status: UpdateStatus.blocked,
          currentVersionCode: 1,
          release: _release,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Time to update'), findsOneWidget);
    expect(find.textContaining('1.4.0'), findsWidgets);
  });
}
