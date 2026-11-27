import 'dart:convert';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends Fake implements FFI {}

class _Binding extends Fake implements RustdeskImpl {
  String token = 'old-login';
  String origin = 'https://account.example.test';
  int clearRequests = 0;
  void Function()? duringOrigin;
  bool replaceAfterClear = false;

  @override
  String mainGetLocalOption({required String key, dynamic hint}) =>
      key == 'access_token' ? token : '';

  @override
  Future<String> mainGetApiServer({dynamic hint}) async {
    await Future<void>.delayed(Duration.zero);
    duringOrigin?.call();
    return origin;
  }

  @override
  Future<String> mainGetCommon({required String key, dynamic hint}) async {
    final request = jsonDecode(key.substring('bk-remote-native:'.length));
    expect(request['op'], 'clear_session');
    expect(request['token'], 'old-login');
    expect(request['audience'], origin);
    clearRequests++;
    if (replaceAfterClear) token = 'new-login';
    return jsonEncode({
      'ok': true,
      'data': {'cleared': replaceAfterClear}
    });
  }
}

void main() {
  late _Binding binding;
  late _Session session;
  late UserModel model;

  setUp(() {
    isTest = true;
    binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    session = _Session();
    model = UserModel(WeakReference(session));
    model.userName.value = 'new-user';
    model.displayName.value = 'New user';
    model.isAdmin.value = true;
  });

  tearDown(() => isTest = false);

  test('a login that changes during origin lookup cannot be invalidated',
      () async {
    binding.duringOrigin = () => binding.token = 'new-login';
    await model.invalidateSession('old-login', binding.origin);
    expect(binding.clearRequests, 0);
    expect(binding.token, 'new-login');
    expect(model.userName.value, 'new-user');
  });

  test('native refusal of a stale cleanup preserves the visible account',
      () async {
    await model.invalidateSession('old-login', binding.origin);
    expect(binding.clearRequests, 1);
    expect(model.userName.value, 'new-user');
    expect(model.isAdmin.value, true);
  });

  test(
      'a new login after native cleanup keeps its account and administrator UI',
      () async {
    binding.replaceAfterClear = true;
    await model.invalidateSession('old-login', binding.origin);
    expect(binding.clearRequests, 1);
    expect(binding.token, 'new-login');
    expect(model.userName.value, 'new-user');
    expect(model.displayName.value, 'New user');
    expect(model.isAdmin.value, true);
  });
}
