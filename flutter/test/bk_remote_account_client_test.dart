import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_hbb/common/bk_remote_account_client.dart';

void main() {
  const origin = 'https://accounts.example.test';
  const identity = {
    'id': '123456789',
    'uuid': 'device-uuid',
    'pk': 'public-key'
  };
  const token = 'test-login-token';

  BkRemoteAccountClient create(MockClient httpClient,
      {BkNativeRequest? native,
      String Function()? currentToken,
      Future<String> Function()? currentOrigin,
      Future<void> Function()? onUnauthorized}) {
    return BkRemoteAccountClient(
      origin: origin,
      token: token,
      identity: identity,
      currentToken: currentToken ?? () => token,
      currentOrigin: currentOrigin ?? () async => origin,
      nativeRequest: native ?? (_) async => {'signature': 'device-signature'},
      onUnauthorized: onUnauthorized,
      client: httpClient,
    );
  }

  test(
      'enrollment and recovery bind the selected device and use no password fields',
      () async {
    for (final recovery in <String?>[null, '987654321']) {
      final paths = <String>[];
      Map<String, dynamic>? signed;
      final client = create(MockClient((request) async {
        paths.add(request.url.path);
        expect(request.followRedirects, false);
        expect(request.headers['Authorization'], 'Bearer $token');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.keys.any((key) => key.toLowerCase().contains('password')),
            false);
        switch (request.url.path) {
          case '/api/bk/devices/enrollment-tokens':
            expect(body['id'], identity['id']);
            expect(body['uuid'], identity['uuid']);
            expect(body['pk'], identity['pk']);
            expect(body['recover_device_id'], recovery);
            return http.Response(
                jsonEncode({'deployment_token': 'one-use-token', 'user_id': 7}),
                201);
          case '/api/bk/devices/challenges':
            expect(body, {'deployment_token': 'one-use-token'});
            return http.Response(
                jsonEncode({
                  'challenge_id': 'challenge-id',
                  'signing_payload': 'encoded-message'
                }),
                201);
          case '/api/bk/devices/enroll':
            expect(body, {
              'challenge_id': 'challenge-id',
              'deployment_token': 'one-use-token',
              'signature': 'device-signature',
            });
            return http.Response(
                jsonEncode({'id': identity['id'], 'state': 'active'}), 200);
          default:
            fail('Unexpected route');
        }
      }), native: (request) async {
        signed = request;
        return {'signature': 'device-signature'};
      });
      await client.enroll(recoverDeviceId: recovery);
      expect(signed!['recover_device_id'], recovery ?? '');
      expect(signed!['user_id'], 7);
      expect(signed!['deployment_token'], 'one-use-token');
      expect(paths, [
        '/api/bk/devices/enrollment-tokens',
        '/api/bk/devices/challenges',
        '/api/bk/devices/enroll',
      ]);
      client.close();
    }
  });

  test('account change prevents a challenge from being signed or submitted',
      () async {
    var activeToken = token;
    var requests = 0;
    final client = create(
        MockClient((request) async {
          requests++;
          activeToken = 'a-different-login';
          return http.Response(
              jsonEncode({'deployment_token': 'one-use-token', 'user_id': 7}),
              200);
        }),
        currentToken: () => activeToken,
        native: (_) async {
          fail('Must not sign after login changes');
        });
    await expectLater(client.enroll(), throwsA(isA<BkRemoteAccountError>()));
    expect(requests, 1);
    client.close();
  });

  test('native refusal never falls back to legacy enrollment', () async {
    final paths = <String>[];
    final client = create(MockClient((request) async {
      paths.add(request.url.path);
      return http.Response(
          jsonEncode(paths.length == 1
              ? {'deployment_token': 'one-use-token', 'user_id': 7}
              : {'challenge_id': 'challenge-id', 'signing_payload': 'message'}),
          200);
    }), native: (_) async {
      throw const BkRemoteAccountError(
          'Enrollment challenge does not match this device or login');
    });
    await expectLater(client.enroll(), throwsA(isA<BkRemoteAccountError>()));
    expect(paths,
        ['/api/bk/devices/enrollment-tokens', '/api/bk/devices/challenges']);
    client.close();
  });

  test('redirect and malformed responses fail without echoing credentials',
      () async {
    for (final status in [302, 200]) {
      var requests = 0;
      final client = create(MockClient((request) async {
        requests++;
        expect(request.followRedirects, false);
        return http.Response('secret-token-and-password', status,
            headers: {'location': 'https://untrusted.example.test'});
      }));
      try {
        await client.devices();
        fail('Expected refusal');
      } on BkRemoteAccountError catch (error) {
        expect(error.toString(), isNot(contains('secret-token')));
      }
      expect(requests, 1);
      client.close();
    }
  });

  test('remote plaintext account endpoints are refused before transmission',
      () {
    final transport = MockClient((_) async {
      fail('Must not transmit credentials');
    });
    expect(
        () => BkRemoteAccountClient(
              origin: 'http://accounts.example.test',
              token: token,
              identity: identity,
              currentToken: () => token,
              currentOrigin: () async => 'http://accounts.example.test',
              nativeRequest: (_) async => {},
              client: transport,
            ),
        throwsA(isA<BkRemoteAccountError>()));
    transport.close();
  });

  test('device list excludes unexpected secret-bearing fields before caching',
      () async {
    final client = create(MockClient((request) async => http.Response(
        jsonEncode({
          'total': 1,
          'data': [
            {
              'id': identity['id'],
              'password': 'forbidden',
              'token': 'forbidden',
              'info': {'device_name': 'device', 'password': 'forbidden'},
              'status': 7,
              'can_manage': true,
            }
          ]
        }),
        200)));
    final devices = await client.devices();
    expect(jsonEncode(devices), isNot(contains('forbidden')));
    expect(devices.single['status'], null);
    client.close();
  });

  test(
      'all authorized devices are loaded across pages without silent truncation',
      () async {
    final pages = <int>[];
    final client = create(MockClient((request) async {
      final page = int.parse(request.url.queryParameters['page']!);
      pages.add(page);
      expect(request.url.queryParameters['pageSize'], '200');
      final start = (page - 1) * 200;
      final count = page == 1 ? 200 : 5;
      return http.Response(
          jsonEncode({
            'total': 205,
            'data':
                List.generate(count, (index) => {'id': '${start + index + 1}'}),
          }),
          200);
    }));
    final devices = await client.devices();
    expect(pages, [1, 2]);
    expect(devices.length, 205);
    expect(devices.last['id'], '205');
    client.close();
  });

  test(
      'inconsistent pages fail instead of presenting an incomplete authorized list',
      () async {
    final client = create(MockClient((request) async {
      final page = int.parse(request.url.queryParameters['page']!);
      return http.Response(
          jsonEncode({
            'total': 201,
            'data': List.generate(
                page == 1 ? 200 : 1, (index) => {'id': '${index + 1}'}),
          }),
          200);
    }));
    await expectLater(client.devices(), throwsA(isA<BkRemoteAccountError>()));
    client.close();
  });

  test('release is distinct from revoking account access', () async {
    final client = create(MockClient((request) async {
      expect(request.url.path, '/api/bk/devices/release');
      return http.Response(
          jsonEncode({
            'id': identity['id'],
            'account_access': 'revoked',
            'ownership': 'released',
            'native_access': 'unchanged',
          }),
          200);
    }));
    await client.release(identity['id']!);
    client.close();
  });

  test(
      'only an invalid login clears the session, not a device permission denial',
      () async {
    for (final status in [401, 403]) {
      var invalidated = 0;
      final client = create(
        MockClient((_) async => http.Response('{"error":"denied"}', status)),
        onUnauthorized: () async => invalidated++,
      );
      await expectLater(
          client.devices(),
          throwsA(isA<BkRemoteAccountError>()
              .having((error) => error.status, 'status', status)));
      expect(invalidated, status == 401 ? 1 : 0);
      client.close();
    }
  });

  test('a login change while origin resolution is pending cannot send or clear',
      () async {
    for (final changeAt in [1, 2]) {
      var activeToken = token;
      var origins = 0;
      var requests = 0;
      var invalidated = 0;
      final client = create(
        MockClient((_) async {
          requests++;
          return http.Response('{"error":"expired"}', 401);
        }),
        currentToken: () => activeToken,
        currentOrigin: () async {
          origins++;
          await Future<void>.delayed(Duration.zero);
          if (origins == changeAt) activeToken = 'a-new-login';
          return origin;
        },
        onUnauthorized: () async => invalidated++,
      );
      await expectLater(
          client.devices(),
          throwsA(isA<BkRemoteAccountError>().having((error) => error.message,
              'message', 'The account or server changed')));
      expect(requests, changeAt == 1 ? 0 : 1);
      expect(invalidated, 0);
      expect(activeToken, 'a-new-login');
      client.close();
    }
  });

  test('a different server after an old 401 cannot clear the current profile',
      () async {
    var actualOrigin = origin;
    var invalidated = false;
    final client = create(
      MockClient((_) async {
        actualOrigin = 'https://a-different-server.example.test';
        return http.Response('{"error":"expired"}', 401);
      }),
      currentOrigin: () async => actualOrigin,
      onUnauthorized: () async => invalidated = true,
    );
    await expectLater(client.devices(), throwsA(isA<BkRemoteAccountError>()));
    expect(invalidated, false);
    client.close();
  });

  test('self-revocation clears the invalidated login on the next real response',
      () async {
    var activeToken = token;
    var invalidated = 0;
    final paths = <String>[];
    final client = create(
      MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/revoke')) {
          return http.Response(
              jsonEncode({
                'id': identity['id'],
                'account_access': 'revoked',
                'native_access': 'unchanged'
              }),
              200);
        }
        return http.Response('{"error":"unauthorized"}', 401);
      }),
      currentToken: () => activeToken,
      onUnauthorized: () async {
        invalidated++;
        activeToken = '';
      },
    );
    await client.revoke(identity['id']!);
    await expectLater(
        client.devices(),
        throwsA(isA<BkRemoteAccountError>()
            .having((error) => error.status, 'status', 401)));
    expect(paths, ['/api/bk/devices/revoke', '/api/bk/devices']);
    expect(invalidated, 1);
    expect(activeToken, '');
    client.close();
  });

  test('revoke requires an explicit account revocation response', () async {
    final client = create(MockClient((request) async => http.Response(
        jsonEncode({'id': identity['id'], 'native_access': 'unchanged'}),
        200)));
    await expectLater(
        client.revoke(identity['id']!), throwsA(isA<BkRemoteAccountError>()));
    client.close();
  });
}
