import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peak/features/feed/post_media_view.dart';

void main() {
  testWidgets('audio post shows its length and a transcript toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PostAudio(
            url: 'https://example.invalid/a.m4a',
            durationMs: 83000,
            transcript: 'Hello from the launch pad.',
          ),
        ),
      ),
    );
    expect(find.text('1:23'), findsOneWidget);
    expect(find.text('Hello from the launch pad.'), findsNothing);
    await tester.tap(find.text('Transcript'));
    await tester.pump();
    expect(find.text('Hello from the launch pad.'), findsOneWidget);
    expect(find.text('Hide transcript'), findsOneWidget);
  });

  testWidgets('no transcript, no toggle', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PostAudio(url: 'https://example.invalid/a.m4a')),
      ),
    );
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Transcript'), findsNothing);
  });
}
