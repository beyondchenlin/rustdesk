import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/bk_remote_update_channel.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends Fake implements RustdeskImpl {
  final String response;
  final keys = <String>[];
  bool customClient = true;
  String uriPrefix = 'bkremote://';
  int updateChecks = 0;

  _Binding(this.response);

  @override
  bool isCustomClient({dynamic hint}) => customClient;

  @override
  String mainUriPrefixSync({dynamic hint}) => uriPrefix;

  @override
  Future<void> mainGetSoftwareUpdateUrl({dynamic hint}) async {
    updateChecks++;
  }

  @override
  Future<String> mainGetCommon({required String key, dynamic hint}) async {
    keys.add(key);
    return response;
  }

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;
}

void main() {
  const notice =
      'The software update channel is not configured. Contact your administrator for a signed installer.';
  const readError = 'Unable to read the software update channel';

  tearDown(() => isTest = false);

  testWidgets(
      'BK update checks remain enabled without changing custom defaults',
      (tester) async {
    isTest = true;
    final binding = _Binding('{"configured":true}');
    platformFFI.setBindingForTesting(binding);
    checkUpdate();
    await tester.pump(const Duration(seconds: 1));
    expect(binding.updateChecks, 1);
    expect(binding.isCustomClient(), true);
  });

  testWidgets('other custom clients keep their upstream update restriction',
      (tester) async {
    isTest = true;
    final binding = _Binding('{"configured":false}')
      ..uriPrefix = 'another-client://';
    platformFFI.setBindingForTesting(binding);
    checkUpdate();
    await tester.pump(const Duration(seconds: 1));
    expect(binding.updateChecks, 0);
  });

  testWidgets('ordinary upstream clients retain their existing update checks',
      (tester) async {
    isTest = true;
    final binding = _Binding('{"configured":true}')
      ..customClient = false
      ..uriPrefix = 'rustdesk://';
    platformFFI.setBindingForTesting(binding);
    checkUpdate();
    await tester.pump(const Duration(seconds: 1));
    expect(binding.updateChecks, 1);
  });

  Future<_Binding> show(WidgetTester tester, String response) async {
    isTest = true;
    final binding = _Binding(response);
    platformFFI.setBindingForTesting(binding);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: BkRemoteUpdateChannelNotice()),
    ));
    await tester.pumpAndSettle();
    expect(binding.keys, ['bk-update-channel']);
    return binding;
  }

  testWidgets(
      'unconfigured software channel displays signed installer guidance',
      (tester) async {
    await show(tester, '{"configured":false}');
    expect(find.text(notice), findsOneWidget);
    expect(find.text(readError), findsNothing);
  });

  testWidgets(
      'configured software channel does not show an unconfigured warning',
      (tester) async {
    await show(tester, '{"configured":true}');
    expect(find.text(notice), findsNothing);
    expect(find.text(readError), findsNothing);
  });

  testWidgets(
      'invalid channel status is reported as unreadable, not configured',
      (tester) async {
    await show(tester, '{"configured":"true"}');
    expect(find.text(readError), findsOneWidget);
    expect(find.text(notice), findsNothing);
  });
}
