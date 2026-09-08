import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadowchat/app/app.dart';

void main() {
  testWidgets('boots to the not-configured screen without a backend', (
    tester,
  ) async {
    // Built without --dart-define, so Env.isConfigured is false and the router
    // sends us to the setup instructions rather than crashing.
    await tester.pumpWidget(const ProviderScope(child: ShadowChatApp()));
    await tester.pumpAndSettle();

    expect(find.text('Backend not configured'), findsOneWidget);
  });
}
