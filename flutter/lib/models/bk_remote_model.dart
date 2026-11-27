import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../common.dart';
import '../common/bk_remote_account_client.dart';
import '../common/bk_remote_native_http_client.dart';
import 'platform_model.dart';

Future<Map<String, dynamic>> bkRemoteNative(Map<String, dynamic> request) =>
    _bkRemoteBridge('bk-remote-native:', request);

Future<Map<String, dynamic>> _bkRemoteBridge(
    String prefix, Map<String, dynamic> request) async {
  final raw = await bind.mainGetCommon(key: '$prefix${jsonEncode(request)}');
  try {
    final response = jsonDecode(raw);
    if (response is Map<String, dynamic> &&
        response['ok'] == true &&
        response['data'] is Map<String, dynamic>) {
      return response['data'];
    }
    final message = response is Map<String, dynamic> ? response['error'] : null;
    throw BkRemoteAccountError(
        message is String ? message : 'The local device identity is invalid');
  } on BkRemoteAccountError {
    rethrow;
  } catch (_) {
    throw const BkRemoteAccountError('The local device identity is invalid');
  }
}

Future<BkRemoteAccountClient> openBkRemoteAccount() async {
  final identity = await bkRemoteNative({'op': 'identity'});
  final token = bind.mainGetLocalOption(key: 'access_token');
  if (token.isEmpty) {
    throw const BkRemoteAccountError(
        'Sign in again to manage team devices', 401);
  }
  final origin = identity['audience'];
  if (origin is! String || identity['id'] != await bind.mainGetMyId()) {
    throw const BkRemoteAccountError('The local device identity is invalid');
  }
  return BkRemoteAccountClient(
    origin: origin,
    token: token,
    identity: identity,
    currentToken: () => bind.mainGetLocalOption(key: 'access_token'),
    currentOrigin: () => bind.mainGetApiServer(),
    nativeRequest: bkRemoteNative,
    client: BkRemoteNativeHttpClient(
      origin: origin,
      token: token,
      invoke: (request) => _bkRemoteBridge('bk-remote-account-http:', request),
    ),
    onUnauthorized: () => gFFI.userModel.invalidateSession(token, origin),
  );
}

String bkRemoteCacheKey(String origin, String user) =>
    'bk-remote-device-cache:${base64UrlEncode(utf8.encode('$origin\u0000$user'))}';

class BkRemotePresence {
  Timer? _timer;
  bool _running = false;
  int _generation = 0;
  String lastError = '';

  void start() {
    if (_timer != null) return;
    _generation++;
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _tick());
    _tick();
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_running) return;
    _running = true;
    final generation = _generation;
    BkRemoteAccountClient? account;
    try {
      account = await openBkRemoteAccount();
      if (generation != _generation) return;
      await account.presence({
        'hostname': Platform.localHostname,
        'os': Platform.operatingSystem,
        'version': version,
      });
      if (generation == _generation) lastError = '';
    } on BkRemoteAccountError catch (error) {
      if (generation == _generation) lastError = error.message;
      if (generation == _generation &&
          (error.status == 401 || error.status == 403)) {
        stop();
      }
    } catch (_) {
      if (generation == _generation) {
        lastError = 'The team device request failed';
      }
    } finally {
      account?.close();
      _running = false;
    }
  }
}

final bkRemotePresence = BkRemotePresence();
