import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bk_remote_account_client.dart';

/// Each request gets a separate native reply. No Dart socket or direct fallback
/// is created, so configured native proxies also govern team-device traffic.
class BkRemoteNativeHttpClient extends http.BaseClient {
  final String origin;
  final String token;
  final BkNativeRequest invoke;
  bool _closed = false;
  static const _maxRequestBytes = 16 * 1024;
  static const _maxResponseBytes = 1024 * 1024;

  BkRemoteNativeHttpClient({
    required this.origin,
    required this.token,
    required this.invoke,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    if (_closed ||
        request.followRedirects ||
        !url.startsWith('$origin/api/bk/devices') ||
        request.headers['Authorization'] != 'Bearer $token' ||
        !['GET', 'POST'].contains(request.method)) {
      throw const BkRemoteAccountError('Invalid team device request');
    }
    final bytes = <int>[];
    await for (final chunk in request.finalize()) {
      if (bytes.length + chunk.length > _maxRequestBytes) {
        throw const BkRemoteAccountError('Invalid team device request');
      }
      bytes.addAll(chunk);
    }
    final response = await invoke({
      'audience': origin,
      'token': token,
      'method': request.method,
      'path': url.substring(origin.length),
      'body': bytes.isEmpty ? null : utf8.decode(bytes),
    });
    if (_closed) {
      throw const BkRemoteAccountError('The team device request failed');
    }
    final status = response['status_code'];
    final body = response['body'];
    if (status is! int || status < 100 || status > 599 || body is! String) {
      throw const BkRemoteAccountError('Invalid account server response');
    }
    final bodyBytes = utf8.encode(body);
    if (bodyBytes.length > _maxResponseBytes) {
      throw const BkRemoteAccountError('Invalid account server response');
    }
    return http.StreamedResponse(Stream.value(bodyBytes), status,
        headers: const {'content-type': 'application/json'}, request: request);
  }

  @override
  void close() {
    _closed = true;
  }
}
