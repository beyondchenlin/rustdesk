import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import '../lib/common/bk_remote_native_presence.dart';

const origin = 'https://account.example';
final contextA = 'a' * 64;
final contextB = 'b' * 64;

String context(String value, {String account = origin, bool ready = true}) =>
    jsonEncode({'context': value, 'origin': account, 'ready': ready});

String response(DateTime now, Map<String, String> states,
        {String? fingerprint, bool verified = true}) =>
    jsonEncode({
      'context': fingerprint ?? contextA,
      'queried_at_ms': now.millisecondsSinceEpoch,
      'confirmed_at_ms': verified ? now.millisecondsSinceEpoch : null,
      'states': states,
    });

void main() {
  test('native observation expires independently of account heartbeat',
      () async {
    var now = DateTime.utc(2026, 11, 27);
    final controller = BkNativePresenceController(
      clock: () => now,
      bridge: (key) async => key == 'bk-native-presence-context'
          ? context(contextA)
          : response(now, {'101': 'online', '202': 'offline'}),
    );
    addTearDown(controller.dispose);
    await controller.refresh(['101', '202'], accountOrigin: origin);
    expect(controller.stateFor('101'), BkNativeRegistrationState.online);
    expect(controller.stateFor('202'), BkNativeRegistrationState.offline);
    expect(controller.lastOnlineAtFor('101'), now);
    expect(controller.lastOnlineAtFor('202'), isNull);
    final observed = controller.observedAtFor('101');
    now = now.add(const Duration(seconds: 30));
    expect(controller.stateFor('101'), BkNativeRegistrationState.unknown);
    expect(controller.stateFor('202'), BkNativeRegistrationState.unknown);
    expect(controller.observedAtFor('101'), observed);
    expect(controller.lastOnlineAtFor('101'), observed);
  });

  test(
      'network failure becomes unknown and preserves only local online history',
      () async {
    var now = DateTime.utc(2026, 11, 27);
    var failure = false;
    final controller = BkNativePresenceController(
      clock: () => now,
      bridge: (key) async {
        if (key == 'bk-native-presence-context') return context(contextA);
        if (failure) throw StateError('offline query transport');
        return response(now, {'101': 'online'});
      },
    );
    addTearDown(controller.dispose);
    await controller.refresh(['101'], accountOrigin: origin);
    final onlineAt = now;
    failure = true;
    now = now.add(const Duration(seconds: 2));
    await controller.refresh(['101'], accountOrigin: origin);
    expect(controller.stateFor('101'), BkNativeRegistrationState.unknown);
    expect(controller.observedAtFor('101'), isNull);
    expect(controller.attemptedAtFor('101'), now);
    expect(controller.lastOnlineAtFor('101'), onlineAt);
  });

  test(
      'unknown signed-query outcome does not manufacture offline or observation',
      () async {
    final now = DateTime.utc(2026, 11, 27);
    final controller = BkNativePresenceController(
      clock: () => now,
      bridge: (key) async => key == 'bk-native-presence-context'
          ? context(contextA)
          : response(now, {'101': 'unknown'}, verified: false),
    );
    addTearDown(controller.dispose);
    await controller.refresh(['101'], accountOrigin: origin);
    expect(controller.stateFor('101'), BkNativeRegistrationState.unknown);
    expect(controller.observedAtFor('101'), isNull);
    expect(controller.lastOnlineAtFor('101'), isNull);
    expect(controller.attemptedAtFor('101'), now);
  });

  test(
      'malformed response, wrong ids and unverified claimed online fail closed',
      () async {
    final now = DateTime.utc(2026, 11, 27);
    for (final raw in [
      response(now, {'202': 'online'}),
      response(now, {'101': 'online'}, fingerprint: contextB),
      response(now, {'101': 'online'}, verified: false),
      response(now, {'101': 'unknown'}),
      response(now.add(const Duration(minutes: 5)), {'101': 'online'}),
      '{"context":',
    ]) {
      final controller = BkNativePresenceController(
        clock: () => now,
        bridge: (key) async =>
            key == 'bk-native-presence-context' ? context(contextA) : raw,
      );
      await controller.refresh(['101'], accountOrigin: origin);
      expect(controller.stateFor('101'), BkNativeRegistrationState.unknown);
      expect(controller.lastOnlineAtFor('101'), isNull);
      controller.dispose();
    }
  });

  test('profile change while query is running discards the old observation',
      () async {
    final now = DateTime.utc(2026, 11, 27);
    var current = contextA;
    final pending = Completer<String>();
    final started = Completer<void>();
    final controller = BkNativePresenceController(
      clock: () => now,
      bridge: (key) async {
        if (key == 'bk-native-presence-context') return context(current);
        started.complete();
        return pending.future;
      },
    );
    addTearDown(controller.dispose);
    final task = controller.refresh(['101'], accountOrigin: origin);
    await started.future;
    current = contextB;
    pending.complete(response(now, {'101': 'online'}));
    await task;
    expect(controller.stateFor('101'), BkNativeRegistrationState.unknown);
    expect(controller.lastOnlineAtFor('101'), isNull);
  });

  test('stale context completion cannot clear a replacement profile state',
      () async {
    final now = DateTime.utc(2026, 11, 27);
    final oldContext = Completer<String>();
    var contextReads = 0;
    final controller = BkNativePresenceController(
      clock: () => now,
      bridge: (key) async {
        if (key == 'bk-native-presence-context') {
          contextReads++;
          if (contextReads == 1) return oldContext.future;
          return context(contextB);
        }
        return response(now, {'101': 'online'}, fingerprint: contextB);
      },
    );
    addTearDown(controller.dispose);
    final old = controller.refresh(['101'], accountOrigin: origin);
    controller.reset();
    await controller.refresh(['101'], accountOrigin: origin);
    expect(controller.stateFor('101'), BkNativeRegistrationState.online);
    oldContext.complete(context('', ready: false));
    await old;
    expect(controller.stateFor('101'), BkNativeRegistrationState.online);
    expect(controller.lastOnlineAtFor('101'), now);
  });

  test('unready or different account contexts never send a native query',
      () async {
    for (final value in [
      context('', ready: false),
      context(contextA, account: 'https://another.example'),
    ]) {
      var calls = 0;
      final controller = BkNativePresenceController(bridge: (key) async {
        calls++;
        expect(key, 'bk-native-presence-context');
        return value;
      });
      await controller.refresh(['101'], accountOrigin: origin);
      expect(calls, 1);
      expect(controller.stateFor('101'), BkNativeRegistrationState.unknown);
      controller.dispose();
    }
  });

  test('duplicate, oversized, invalid and excessive identifiers never query',
      () async {
    for (final ids in [
      ['101', '101'],
      ['bad\nidentifier'],
      ['x' * 254],
      List.generate(201, (i) => '$i'),
      List.generate(70, (i) => '${i.toString().padLeft(3, '0')}${'x' * 250}'),
    ]) {
      var calls = 0;
      final controller = BkNativePresenceController(bridge: (key) async {
        calls++;
        return '';
      });
      await controller.refresh(ids, accountOrigin: origin);
      expect(calls, 0);
      expect(controller.stateFor('101'), BkNativeRegistrationState.unknown);
      controller.dispose();
    }
  });

  test('concurrent refresh is bounded and input identifiers are snapshotted',
      () async {
    final now = DateTime.utc(2026, 11, 27);
    final contextGate = Completer<String>();
    var queries = 0;
    var reads = 0;
    final controller = BkNativePresenceController(
      clock: () => now,
      bridge: (key) async {
        if (key == 'bk-native-presence-context') {
          reads++;
          if (reads == 1) return await contextGate.future;
          return context(contextA);
        }
        queries++;
        final sent = jsonDecode(key.substring('bk-native-presence:'.length));
        expect(sent['ids'], ['101']);
        return response(now, {'101': 'online'});
      },
    );
    addTearDown(controller.dispose);
    final ids = ['101'];
    final task = controller.refresh(ids, accountOrigin: origin);
    ids[0] = '202';
    await controller.refresh(['303'], accountOrigin: origin);
    contextGate.complete(context(contextA));
    await task;
    expect(queries, 1);
    expect(controller.stateFor('101'), BkNativeRegistrationState.online);
    expect(controller.stateFor('202'), BkNativeRegistrationState.unknown);
  });
}
