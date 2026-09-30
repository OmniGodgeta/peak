import 'package:flutter_test/flutter_test.dart';
import 'package:peak/features/moderation/transparency_report_screen.dart';

void main() {
  test('suppressed counts read as "fewer than 5"', () {
    expect(formatReportCount(-1), 'fewer than 5');
    expect(formatReportCount(0), '0');
    expect(formatReportCount(12), '12');
    expect(formatReportCount(null), '—');
  });

  test('quarter arithmetic', () {
    expect(quarterOf(DateTime.utc(2026, 9, 30)), (year: 2026, quarter: 3));
    expect(quarterOf(DateTime.utc(2026, 10, 1)), (year: 2026, quarter: 4));
    expect(previousQuarter((year: 2027, quarter: 1)), (year: 2026, quarter: 4));
    expect(previousQuarter((year: 2026, quarter: 3)), (year: 2026, quarter: 2));
  });
}
