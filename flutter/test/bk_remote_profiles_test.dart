import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/bk_remote_profiles.dart';

void main() {
  test('Android handoff failure restores the original selection before error',
      () async {
    final operations = <String>[];
    final controller = BkProfileController(
      request: (request) async {
        operations.add(request['op'] as String);
        if (request['op'] == 'switch_profile') {
          expect(request['target'], 'official');
          expect(request['generation'], 7);
          return {'restart': 'android'};
        }
        return {'restored': true};
      },
      restartAndroid: () async => false,
    );
    await expectLater(
        controller.switchTo('official', 7),
        throwsA(isA<StateError>().having((e) => e.message, 'restored',
            contains('previous server profile was restored'))));
    expect(operations, ['switch_profile', 'abort_profile_switch']);
  });

  test('Android accepted restart does not revert the selected profile',
      () async {
    final operations = <String>[];
    final controller = BkProfileController(
      request: (request) async {
        operations.add(request['op'] as String);
        return {'restart': 'android'};
      },
      restartAndroid: () async => true,
    );
    expect(await controller.switchTo('manual', 2), 'android');
    expect(operations, ['switch_profile']);
  });

  test('Windows coordinator never invokes Android or claims completion',
      () async {
    var androidCalls = 0;
    final controller = BkProfileController(
      request: (request) async => {'restart': 'automatic'},
      restartAndroid: () async {
        androidCalls++;
        return true;
      },
    );
    expect(await controller.switchTo('bk', 3), 'automatic');
    expect(androidCalls, 0);
  });

  test('failed recovery is reported without claiming restored configuration',
      () async {
    final controller = BkProfileController(
      request: (request) async => request['op'] == 'switch_profile'
          ? {'restart': 'android'}
          : {'restored': false},
      restartAndroid: () async => throw StateError('handoff denied'),
    );
    await expectLater(
        controller.switchTo('manual', 3),
        throwsA(isA<StateError>().having((e) => e.message, 'recovery',
            contains('reopen the server profile page to recover'))));
  });

  test('invalid profiles and malformed state cannot start a switch', () async {
    var calls = 0;
    final controller = BkProfileController(
      request: (request) async {
        calls++;
        return {'profile': 'unexpected'};
      },
      restartAndroid: () async => true,
    );
    await expectLater(controller.switchTo('../other', 0), throwsArgumentError);
    expect(calls, 0);
    await expectLater(controller.load(), throwsStateError);
  });

  test('recovery preserves the expected generation and explicit intent',
      () async {
    final controller = BkProfileController(
      request: (request) async {
        expect(request['recover'], true);
        expect(request['generation'], 9);
        return {'restart': 'automatic'};
      },
      restartAndroid: () async => true,
    );
    await controller.switchTo('bk', 9, recover: true);
  });
}
