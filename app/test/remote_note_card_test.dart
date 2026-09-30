import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peak/data/federation_repository.dart';
import 'package:peak/features/federation/remote_note_card.dart';

RemoteNote _n({String? cw}) => RemoteNote(
  id: '1',
  uri: 'https://m.example/notes/1',
  url: 'https://m.example/@zed/1',
  body: 'Hello <b>not bold</b>',
  contentWarning: cw,
  publishedAt: DateTime.now(),
  actorHandle: 'zed@m.example',
  actorName: 'Zed',
  actorIcon: null,
);

void main() {
  testWidgets('shows remote text as plain text', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RemoteNoteCard(note: _n())),
      ),
    );
    expect(find.text('Hello <b>not bold</b>'), findsOneWidget);
    expect(find.text('@zed@m.example'), findsOneWidget);
    expect(find.text('Open original'), findsOneWidget);
  });

  testWidgets('content warning hides the body until tapped', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteNoteCard(note: _n(cw: 'spoilers')),
        ),
      ),
    );
    expect(find.text('Hello <b>not bold</b>'), findsNothing);
    await t.tap(find.textContaining('spoilers'));
    await t.pump();
    expect(find.text('Hello <b>not bold</b>'), findsOneWidget);
  });
}
