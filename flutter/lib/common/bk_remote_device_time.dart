/// The account API reports whole Unix seconds, never milliseconds.
/// Unknown, malformed, or non-calendar values must not become a current time.
DateTime? parseBkRemoteAccountTime(Object? value) {
  num? seconds;
  if (value is num) {
    seconds = value;
  } else if (value is String) {
    final text = value.trim();
    if (RegExp(r'^[0-9]{1,12}$').hasMatch(text)) {
      seconds = int.tryParse(text);
    }
  }
  // Bound the displayed calendar to years through 9999. This also rejects a
  // present-day millisecond value instead of silently guessing a different unit.
  if (seconds == null ||
      !seconds.isFinite ||
      seconds <= 0 ||
      seconds > 253402300799 ||
      seconds % 1 != 0) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(
      seconds.toInt() * Duration.millisecondsPerSecond,
      isUtc: true);
}

/// Display the actual instant in the viewer's local zone, to whole seconds.
/// The numeric offset makes date boundaries explicit without new locale keys.
String formatBkRemoteDeviceTime(DateTime? value) {
  if (value == null || value.millisecondsSinceEpoch <= 0) return '—';
  final local = value.toLocal();
  if (local.year < 1 || local.year > 9999) return '—';
  String two(int number) => number.toString().padLeft(2, '0');
  final date = [
    local.year.toString().padLeft(4, '0'),
    two(local.month),
    two(local.day),
  ].join('-');
  final time = [two(local.hour), two(local.minute), two(local.second)].join(':');
  final offsetMinutes = local.timeZoneOffset.inMinutes;
  final sign = offsetMinutes < 0 ? '-' : '+';
  final absoluteMinutes = offsetMinutes.abs();
  final offset = sign +
      two(absoluteMinutes ~/ Duration.minutesPerHour) +
      ':' +
      two(absoluteMinutes % Duration.minutesPerHour);
  return '$date $time $offset';
}
