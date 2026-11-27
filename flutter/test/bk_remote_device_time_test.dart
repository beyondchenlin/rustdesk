import 'package:flutter_test/flutter_test.dart';

import '../lib/common/bk_remote_device_time.dart';

DateTime renderedInstant(String displayed) =>
    DateTime.parse(displayed.replaceFirst(' ', 'T').replaceFirst(' ', ''));

void main() {
  test('account seconds and decimal strings preserve the exact UTC instant', () {
    final expected = DateTime.utc(2026, 11, 27, 16, 23, 17);
    for (final value in [1795796597, '1795796597', ' 1795796597 ']) {
      final parsed = parseBkRemoteAccountTime(value);
      expect(parsed, expected);
      expect(parsed!.isUtc, isTrue);
    }
  });

  test('an integral JSON number is accepted without fractional truncation', () {
    expect(parseBkRemoteAccountTime(1795796597.0),
        DateTime.utc(2026, 11, 27, 16, 23, 17));
    expect(parseBkRemoteAccountTime(1795796597.5), isNull);
  });

  test('missing zero and malformed values remain unknown', () {
    for (final value in <Object?>[
      null, '', '  ', 0, 0.0, '0', '000', -1, '-1', true,
      [], <String, Object?>{}, 'unknown', '2026-11-27T16:23:17Z',
      '1795796597.0', '+1795796597', '1e9', double.nan, double.infinity,
    ]) {
      expect(parseBkRemoteAccountTime(value), isNull, reason: '$value');
      expect(formatBkRemoteDeviceTime(parseBkRemoteAccountTime(value)), '—');
    }
  });

  test('wrong units and values beyond the calendar bound are rejected', () {
    for (final value in [
      1795796597000, '1795796597000', 253402300800, '999999999999999999999',
    ]) {
      expect(parseBkRemoteAccountTime(value), isNull, reason: '$value');
    }
  });

  test('the supported upper second is parsed without changing units', () {
    expect(parseBkRemoteAccountTime(253402300799),
        DateTime.utc(9999, 12, 31, 23, 59, 59));
  });

  test('missing or invalid observation dates never display epoch or now', () {
    expect(formatBkRemoteDeviceTime(null), '—');
    expect(formatBkRemoteDeviceTime(
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)), '—');
    expect(formatBkRemoteDeviceTime(
        DateTime.fromMillisecondsSinceEpoch(-1, isUtc: true)), '—');
    expect(formatBkRemoteDeviceTime(DateTime.utc(10001)), '—');
  });

  test('local date display removes fractions and includes its true offset', () {
    final value = DateTime(2026, 11, 28, 0, 23, 17, 123, 456);
    final displayed = formatBkRemoteDeviceTime(value);
    expect(displayed,
        matches(r'^2026-11-28 00:23:17 [+-][0-9]{2}:[0-9]{2}$'));
    expect(renderedInstant(displayed),
        DateTime(2026, 11, 28, 0, 23, 17).toUtc());
  });

  test(
      'UTC input round trips across local date and offset boundaries '
      '(offset ${DateTime.utc(2026, 11, 27).toLocal().timeZoneOffset.inMinutes})',
      () {
    final instant = DateTime.utc(2026, 11, 27, 16, 23, 17, 321, 654);
    final displayed = formatBkRemoteDeviceTime(instant);
    expect(renderedInstant(displayed),
        DateTime.utc(2026, 11, 27, 16, 23, 17));
    final minutes = instant.toLocal().timeZoneOffset.inMinutes;
    // The focused runner exercises all three real process time zones. These
    // assertions also remain valid when the whole suite uses a different zone.
    if (minutes == 0) {
      expect(displayed, '2026-11-27 16:23:17 +00:00');
    } else if (minutes == 480) {
      expect(displayed, '2026-11-28 00:23:17 +08:00');
    } else if (minutes == -210) {
      expect(displayed, '2026-11-27 12:53:17 -03:30');
    }
  });

  test('different explicit input offsets describe the same observed instant', () {
    final positive = DateTime.parse('2026-11-28T00:23:17+08:00');
    final negative = DateTime.parse('2026-11-27T10:53:17-05:30');
    final utc = DateTime.utc(2026, 11, 27, 16, 23, 17);
    expect(formatBkRemoteDeviceTime(positive), formatBkRemoteDeviceTime(utc));
    expect(formatBkRemoteDeviceTime(negative), formatBkRemoteDeviceTime(utc));
  });
}
