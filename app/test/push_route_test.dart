import 'package:flutter_test/flutter_test.dart';
import 'package:peak/push/push_service.dart';

void main() {
  test('push taps route to the right place', () {
    expect(pushRoute({'t': 'message', 'ref': 'c1'}), '/messages');
    expect(pushRoute({'t': 'notice'}), '/feed');
    expect(pushRoute({}), '/feed');
    expect(
      pushRoute({'t': 'call', 'room': 'r1', 'body': 'Ada is calling'}),
      '/call/r1?title=Ada+is+calling',
    );
    expect(pushRoute({'t': 'call'}), '/messages');
  });
}
