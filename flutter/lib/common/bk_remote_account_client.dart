import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

typedef BkNativeRequest = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> request);

class BkRemoteAccountError implements Exception {
  final String message;
  final int? status;
  const BkRemoteAccountError(this.message, [this.status]);
  @override
  String toString() => message;
}

class BkRemoteAccountClient {
  final String origin;
  final String token;
  final Map<String, dynamic> identity;
  final String Function() currentToken;
  final Future<String> Function() currentOrigin;
  final BkNativeRequest nativeRequest;
  final Future<void> Function()? onUnauthorized;
  final http.Client _http;
  static const _timeout = Duration(seconds: 20);
  static const _maxResponseBytes = 1024 * 1024;

  BkRemoteAccountClient({
    required this.origin,
    required this.token,
    required this.identity,
    required this.currentToken,
    required this.currentOrigin,
    required this.nativeRequest,
    this.onUnauthorized,
    http.Client? client,
  }) : _http = client ?? http.Client() {
    final uri = Uri.tryParse(origin);
    final loopback =
        uri != null && ['localhost', '127.0.0.1', '::1'].contains(uri.host);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        token.isEmpty) {
      throw const BkRemoteAccountError('Configure the account server first');
    }
  }

  void close() => _http.close();

  Future<void> checkSession() async {
    if (currentToken() != token) {
      throw const BkRemoteAccountError('The account or server changed');
    }
    final actualOrigin =
        (await currentOrigin()).replaceFirst(RegExp(r'/+$'), '');
    // Resolving the native origin yields: a different login can complete while
    // it is in flight, so both identity dimensions must be checked afterwards.
    if (currentToken() != token || actualOrigin != origin) {
      throw const BkRemoteAccountError('The account or server changed');
    }
  }

  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    await checkSession();
    if (!path.startsWith('/api/bk/devices')) {
      throw const BkRemoteAccountError('Invalid team device request');
    }
    final request =
        http.Request(body == null ? 'GET' : 'POST', Uri.parse('$origin$path'))
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          });
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await _http.send(request).timeout(_timeout);
      Future<List<int>> readBody() async {
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > _maxResponseBytes) {
            throw const BkRemoteAccountError('Invalid account server response');
          }
          bytes.addAll(chunk);
        }
        return bytes;
      }

      final bytes = await readBody().timeout(_timeout);
      await checkSession();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401) await onUnauthorized?.call();
        final message = switch (response.statusCode) {
          401 => 'Sign in again to manage team devices',
          403 => 'Device registration or permission is required',
          409 => 'Device identity conflicts with an existing registration',
          410 => 'The enrollment challenge expired',
          503 => 'Device identity verification is unavailable',
          _ => 'The team device request failed',
        };
        throw BkRemoteAccountError(message, response.statusCode);
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> || value.containsKey('error')) {
        throw const BkRemoteAccountError('Invalid account server response');
      }
      return value;
    } on BkRemoteAccountError {
      rethrow;
    } catch (_) {
      // Raw HTTP exceptions and responses can contain enrollment credentials.
      throw const BkRemoteAccountError('The team device request failed');
    }
  }

  Future<void> enroll({String? recoverDeviceId}) async {
    final issue = await request('/api/bk/devices/enrollment-tokens', body: {
      'id': identity['id'],
      'uuid': identity['uuid'],
      'pk': identity['pk'],
      if (recoverDeviceId != null) 'recover_device_id': recoverDeviceId,
    });
    final deploymentToken = issue['deployment_token'];
    final userId = issue['user_id'];
    if (deploymentToken is! String ||
        deploymentToken.isEmpty ||
        userId is! int ||
        userId <= 0) {
      throw const BkRemoteAccountError('Invalid account server response');
    }
    final challenge = await request('/api/bk/devices/challenges', body: {
      'deployment_token': deploymentToken,
    });
    final challengeId = challenge['challenge_id'];
    final payload = challenge['signing_payload'];
    if (challengeId is! String || payload is! String) {
      throw const BkRemoteAccountError('Invalid account server response');
    }
    await checkSession();
    final signed = await nativeRequest({
      'op': 'sign_enrollment',
      'deployment_token': deploymentToken,
      'user_id': userId,
      'recover_device_id': recoverDeviceId ?? '',
      'challenge_id': challengeId,
      'signing_payload': payload,
    });
    final signature = signed['signature'];
    if (signature is! String || signature.isEmpty) {
      throw const BkRemoteAccountError('The local device identity is invalid');
    }
    final enrolled = await request('/api/bk/devices/enroll', body: {
      'challenge_id': challengeId,
      'deployment_token': deploymentToken,
      'signature': signature,
    });
    if (enrolled['id'] != identity['id'] || enrolled['state'] != 'active') {
      throw const BkRemoteAccountError('Invalid account server response');
    }
  }

  Future<List<Map<String, dynamic>>> devices() async {
    const pageSize = 200;
    final devices = <String, Map<String, dynamic>>{};
    int? expectedTotal;
    for (var page = 1;; page++) {
      final result =
          await request('/api/bk/devices?page=$page&pageSize=$pageSize');
      final data = result['data'];
      final total = result['total'];
      if (total is! int ||
          total < 0 ||
          total > 100000 ||
          data is! List ||
          data.length > pageSize ||
          data.any((e) => e is! Map<String, dynamic>) ||
          (expectedTotal != null && total != expectedTotal)) {
        throw const BkRemoteAccountError('Invalid account server response');
      }
      expectedTotal = total;
      for (final device in data.cast<Map<String, dynamic>>()) {
        final id = device['id'];
        if (id is! String || id.isEmpty) {
          throw const BkRemoteAccountError('Invalid account server response');
        }
        devices[id] = device;
      }
      if (page * pageSize >= total) {
        if (devices.length != total) {
          throw const BkRemoteAccountError('Invalid account server response');
        }
        break;
      }
      if (data.length != pageSize) {
        throw const BkRemoteAccountError('Invalid account server response');
      }
    }
    return devices.values.map((device) {
      if (device['id'] is! String || (device['id'] as String).isEmpty) {
        throw const BkRemoteAccountError('Invalid account server response');
      }
      final info = device['info'] is Map ? device['info'] as Map : {};
      return <String, dynamic>{
        'id': device['id'],
        'info': {
          for (final key in ['device_name', 'os', 'username'])
            if (info[key] is String) key: info[key],
        },
        for (final key in [
          'user',
          'user_name',
          'note',
          'device_group_name',
          'last_online_time',
          'state',
        ])
          if (device[key] is String || device[key] is num) key: device[key],
        'status': [0, 1].contains(device['status']) ? device['status'] : null,
        'can_manage': device['can_manage'] == true,
      };
    }).toList();
  }

  Future<void> revoke(String id) async {
    final result = await request('/api/bk/devices/revoke', body: {'id': id});
    if (result['id'] != id || result['account_access'] != 'revoked') {
      throw const BkRemoteAccountError('Invalid account server response');
    }
  }

  Future<void> release(String id) async {
    final result = await request('/api/bk/devices/release', body: {'id': id});
    if (result['id'] != id ||
        result['account_access'] != 'revoked' ||
        result['ownership'] != 'released') {
      throw const BkRemoteAccountError('Invalid account server response');
    }
  }

  Future<void> grant(String id, int userId, {required bool revoke}) async {
    await request('/api/bk/devices/grants',
        body: {'id': id, 'user_id': userId, 'revoke': revoke});
  }

  Future<void> presence(Map<String, dynamic> information) async {
    await request('/api/bk/devices/presence',
        body: {...information, 'id': identity['id']});
  }
}
