import 'dart:convert';

import 'package:flutter_hbb/common/bk_remote_account_client.dart';
import 'package:flutter_hbb/common/bk_remote_native_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  const origin = 'https://accounts.example.test';
  const token = 'fixture-login';

  test(
      'enrollment uses separate native requests and preserves actual 201 replies',
      () async {
    final routes = <String>[];
    final transport = BkRemoteNativeHttpClient(
      origin: origin,
      token: token,
      invoke: (request) async {
        expect(request['audience'], origin);
        expect(request['token'], token);
        expect(request['method'], 'POST');
        expect(jsonDecode(request['body'] as String), isA<Map>());
        routes.add(request['path'] as String);
        final data = switch (routes.length) {
          1 => {'deployment_token': 'fixture-deployment', 'user_id': 9},
          2 => {'challenge_id': 'fixture-challenge', 'signing_payload': 'raw'},
          _ => {'id': '123456789', 'state': 'active'},
        };
        return {
          'status_code': routes.length < 3 ? 201 : 200,
          'body': jsonEncode(data)
        };
      },
    );
    final account = BkRemoteAccountClient(
      origin: origin,
      token: token,
      identity: {
        'id': '123456789',
        'uuid': 'fixture-uuid',
        'pk': 'fixture-key'
      },
      currentToken: () => token,
      currentOrigin: () async => origin,
      nativeRequest: (_) async => {'signature': 'fixture-signature'},
      client: transport,
    );
    await account.enroll();
    expect(routes, [
      '/api/bk/devices/enrollment-tokens',
      '/api/bk/devices/challenges',
      '/api/bk/devices/enroll'
    ]);
    account.close();
  });

  test('native proxy failure is propagated without a direct transport retry',
      () async {
    var calls = 0;
    final transport = BkRemoteNativeHttpClient(
      origin: origin,
      token: token,
      invoke: (_) async {
        calls++;
        throw const BkRemoteAccountError('The team device request failed');
      },
    );
    final request = http.Request('GET', Uri.parse('$origin/api/bk/devices'))
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $token';
    await expectLater(
        transport.send(request), throwsA(isA<BkRemoteAccountError>()));
    expect(calls, 1);
    transport.close();
  });

  test('different origins or bearer values never reach the native transport',
      () async {
    var calls = 0;
    final transport = BkRemoteNativeHttpClient(
      origin: origin,
      token: token,
      invoke: (_) async {
        calls++;
        return {'status_code': 200, 'body': '{}'};
      },
    );
    for (final foreignOrigin in [true, false]) {
      final server = foreignOrigin ? 'https://other.example.test' : origin;
      final request = http.Request('GET', Uri.parse('$server/api/bk/devices'))
        ..followRedirects = false
        ..headers['Authorization'] =
            foreignOrigin ? 'Bearer $token' : 'Bearer other-login';
      await expectLater(
          transport.send(request), throwsA(isA<BkRemoteAccountError>()));
    }
    expect(calls, 0);
    transport.close();
  });

  test('native redirects are exposed as refusals and never followed', () async {
    var calls = 0;
    final transport = BkRemoteNativeHttpClient(
      origin: origin,
      token: token,
      invoke: (_) async {
        calls++;
        return {'status_code': 302, 'body': '{}'};
      },
    );
    final account = BkRemoteAccountClient(
      origin: origin,
      token: token,
      identity: const {},
      currentToken: () => token,
      currentOrigin: () async => origin,
      nativeRequest: (_) async => const {},
      client: transport,
    );
    await expectLater(
        account.devices(),
        throwsA(isA<BkRemoteAccountError>()
            .having((error) => error.status, 'status', 302)));
    expect(calls, 1);
    account.close();
  });
}
