import 'package:flutter_test/flutter_test.dart';
import 'package:peak/data/feed_repository.dart';

PostMedia _m(String path, {String? hls}) => PostMedia(
  kind: 'video',
  storagePath: path,
  altText: null,
  width: null,
  height: null,
  hlsPath: hls,
);

void main() {
  const u = '11111111-1111-4111-8111-111111111111';
  const v = '22222222-2222-4222-8222-222222222222';

  test('stored hls_path wins', () {
    expect(hlsFor(_m('x', hls: 'https://m/x.m3u8')), 'https://m/x.m3u8');
  });

  test('media-server MP4s get the backfill location', () {
    expect(
      hlsFor(_m('https://box.ts.net:8790/v1/media/$u/$v.mp4')),
      'https://box.ts.net:8790/v1/media/$u/$v/master.m3u8',
    );
  });

  test('bucket paths and other URLs have no HLS', () {
    expect(hlsFor(_m('$u/$v.mp4')), isNull);
    expect(hlsFor(_m('https://cdn.example/video.mp4')), isNull);
  });
}
