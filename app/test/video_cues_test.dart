import 'package:flutter_test/flutter_test.dart';
import 'package:peak/data/creator_repository.dart';
import 'package:peak/features/profile/creator_video_editor_sheet.dart';

void main() {
  test('parseCueTime reads s, m:ss and h:mm:ss', () {
    expect(parseCueTime('45'), const Duration(seconds: 45));
    expect(parseCueTime('1:05'), const Duration(minutes: 1, seconds: 5));
    expect(parseCueTime(' 1:02:03 '),
        const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(parseCueTime(''), isNull);
    expect(parseCueTime('a:10'), isNull);
    expect(parseCueTime('-1'), isNull);
    expect(parseCueTime('1:2:3:4'), isNull);
  });

  test('formatCueTime round-trips through parseCueTime', () {
    for (final d in const [
      Duration.zero,
      Duration(seconds: 9),
      Duration(minutes: 12, seconds: 30),
      Duration(hours: 2, minutes: 3, seconds: 4),
    ]) {
      expect(parseCueTime(formatCueTime(d)), d);
    }
    expect(formatCueTime(const Duration(minutes: 1, seconds: 5)), '1:05');
    expect(formatCueTime(const Duration(hours: 1, seconds: 5)), '1:00:05');
  });

  test('VideoExtras parses the video_extras RPC shape', () {
    final x = VideoExtras.fromMap({
      'media_id': 'm1',
      'chapters': [
        {'label': 'Intro', 'start_ms': 0, 'end_ms': 30000},
        {'label': 'Launch', 'start_ms': 30000, 'end_ms': 90000},
      ],
      'captions': [
        {'language': 'en', 'text': 'Hello', 'start_ms': 1000, 'end_ms': 2500},
      ],
    });
    expect(x.mediaId, 'm1');
    expect(x.chapters.map((c) => c.text), ['Intro', 'Launch']);
    expect(x.captions.single.covers(const Duration(milliseconds: 1000)), isTrue);
    expect(x.captions.single.covers(const Duration(milliseconds: 2500)), isFalse);
  });

  test('VideoExtras tolerates missing lists', () {
    final x = VideoExtras.fromMap({'media_id': 'm2'});
    expect(x.chapters, isEmpty);
    expect(x.captions, isEmpty);
  });
}
