import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Native registration is independent of account heartbeat and capture/input permission.
enum BkNativeRegistrationState { online, offline, unknown }

class _Observation {
  const _Observation(this.state, this.attemptedAt, this.observedAt);
  final BkNativeRegistrationState state;
  final DateTime attemptedAt;
  final DateTime? observedAt;
}

/// All known values come from the native verifier. A failed query is never offline.
class BkNativePresenceController extends ChangeNotifier {
  BkNativePresenceController({
    required Future<String> Function(String) bridge,
    DateTime Function()? clock,
  })  : _bridge = bridge,
        _clock = clock ?? DateTime.now;

  static const maxPeers = 200;
  static const freshness = Duration(seconds: 30);
  final Future<String> Function(String) _bridge;
  final DateTime Function() _clock;
  final Map<String, _Observation> _observations = {};
  final Map<String, DateTime> _lastOnline = {};
  String _context = '';
  String _origin = '';
  int _epoch = 0;
  bool _busy = false;
  bool _disposed = false;
  Timer? _expiryTimer;

  BkNativeRegistrationState stateFor(String id) {
    final observation = _observations[id];
    final observed = observation?.observedAt;
    if (observation == null || observed == null) {
      return BkNativeRegistrationState.unknown;
    }
    final age = _clock().difference(observed);
    if (age.isNegative || age >= freshness) {
      return BkNativeRegistrationState.unknown;
    }
    return observation.state;
  }

  /// Local successful verification time, including an older observation when it expires.
  DateTime? observedAtFor(String id) => _observations[id]?.observedAt;
  DateTime? attemptedAtFor(String id) => _observations[id]?.attemptedAt;

  /// Local history only; never represented as a rendezvous server's historical last-online time.
  DateTime? lastOnlineAtFor(String id) => _lastOnline[id];

  Future<void> refresh(List<String> inputIds,
      {required String accountOrigin}) async {
    if (_disposed) return;
    final ids = List<String>.unmodifiable(inputIds);
    final origin = accountOrigin.replaceFirst(RegExp(r'/+$'), '');
    if (_origin != origin) reset();
    if (_busy) return;
    _origin = origin;
    final epoch = ++_epoch;
    final attempted = _clock();
    if (!_validIds(ids) || origin.isEmpty) {
      _observations.clear();
      _scheduleExpiry();
      notifyListeners();
      return;
    }
    _busy = true;
    try {
      final contextRaw = await _bridge('bk-native-presence-context');
      if (!_current(epoch)) return;
      final context = _readContext(contextRaw, origin);
      if (_context != context) {
        _observations.clear();
        _lastOnline.clear();
        _context = context;
      }
      final raw = await _bridge('bk-native-presence:' +
              jsonEncode({'context': context, 'ids': ids}))
          .timeout(const Duration(seconds: 15));
      if (!_current(epoch)) return;
      final afterRaw = await _bridge('bk-native-presence-context');
      if (!_current(epoch)) return;
      final after = _readContext(afterRaw, origin);
      if (after != context) {
        _observations.clear();
        _lastOnline.clear();
        _context = '';
        throw const FormatException('Native registration context changed');
      }
      final response = jsonDecode(raw);
      if (response is! Map<String, dynamic> || response['context'] != context) {
        throw const FormatException('Invalid native registration context');
      }
      final states = response['states'];
      if (states is! Map<String, dynamic> ||
          states.length != ids.length ||
          ids.any((id) => !states.containsKey(id))) {
        throw const FormatException('Invalid native registration identifiers');
      }
      final queried = _timestamp(response['queried_at_ms']);
      final confirmed = response['confirmed_at_ms'] == null
          ? null
          : _timestamp(response['confirmed_at_ms']);
      if (queried.isBefore(attempted.subtract(const Duration(seconds: 1))) ||
          queried.isAfter(_clock().add(const Duration(seconds: 1))) ||
          (confirmed != null &&
              (confirmed.isBefore(queried) ||
                  confirmed
                      .isAfter(_clock().add(const Duration(seconds: 1)))))) {
        throw const FormatException(
            'Invalid native registration observation time');
      }
      final parsed = <String, _Observation>{};
      for (final id in ids) {
        final state = switch (states[id]) {
          'online' => BkNativeRegistrationState.online,
          'offline' => BkNativeRegistrationState.offline,
          'unknown' => BkNativeRegistrationState.unknown,
          _ => throw const FormatException('Invalid native registration state'),
        };
        if ((confirmed == null) !=
            (state == BkNativeRegistrationState.unknown)) {
          throw const FormatException('Unverified native registration state');
        }
        parsed[id] = _Observation(state, queried, confirmed);
      }
      _observations.addAll(parsed);
      for (final entry in parsed.entries) {
        if (entry.value.state == BkNativeRegistrationState.online &&
            entry.value.observedAt != null) {
          _lastOnline[entry.key] = entry.value.observedAt!;
        }
      }
      _scheduleExpiry();
    } catch (_) {
      if (_current(epoch)) _unknown(ids, attempted);
    } finally {
      if (_current(epoch)) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  bool _current(int epoch) => !_disposed && _epoch == epoch;

  String _readContext(String raw, String origin) {
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data['ready'] != true ||
        data['origin'] != origin ||
        data['context'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['context'] as String)) {
      // Unavailable settings cannot preserve observations from an earlier namespace.
      _observations.clear();
      _lastOnline.clear();
      _context = '';
      throw const FormatException('Native registration context unavailable');
    }
    return data['context'] as String;
  }

  static bool _validIds(List<String> ids) {
    if (ids.isEmpty ||
        ids.length > maxPeers ||
        ids.toSet().length != ids.length) {
      return false;
    }
    var total = 0;
    for (final id in ids) {
      if (id.length > 253 ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]*$').hasMatch(id)) {
        return false;
      }
      total += id.length; // The accepted grammar is ASCII.
      if (total > 16 * 1024) return false;
    }
    return true;
  }

  static DateTime _timestamp(dynamic value) {
    if (value is! int || value <= 0) {
      throw const FormatException('Invalid native registration timestamp');
    }
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  void _unknown(List<String> ids, DateTime attempted) {
    for (final id in ids) {
      _observations[id] =
          _Observation(BkNativeRegistrationState.unknown, attempted, null);
    }
    _scheduleExpiry();
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    Duration? delay;
    final now = _clock();
    for (final observation in _observations.values) {
      final observed = observation.observedAt;
      if (observed == null) continue;
      final remaining = observed.add(freshness).difference(now);
      if (remaining > Duration.zero && (delay == null || remaining < delay)) {
        delay = remaining;
      }
    }
    if (delay != null) {
      _expiryTimer = Timer(delay, () {
        if (_disposed) return;
        notifyListeners();
        _scheduleExpiry();
      });
    }
  }

  void reset() {
    _epoch++;
    _busy = false;
    _context = '';
    _origin = '';
    _observations.clear();
    _lastOnline.clear();
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _expiryTimer?.cancel();
    super.dispose();
  }
}
