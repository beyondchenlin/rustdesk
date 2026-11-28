import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/bk_remote_profile_status.dart';
import 'package:flutter_hbb/common/bk_remote_profiles.dart';

Map<String, dynamic> profileState({
  String profile = 'bk',
  String phase = 'stable',
  bool ready = true,
  bool restartRequired = false,
  String? error,
}) =>
    {
      'profile': profile,
      'generation': 1,
      'phase': phase,
      'ready': ready,
      'restart_required': restartRequired,
      'error': error,
    };

void main() {
  test('missing BK configuration reports the blocker without changing profile',
      () async {
    final requests = <Map<String, dynamic>>[];
    final controller = BkProfileController(
      request: (request) async {
        requests.add(request);
        return profileState(ready: false);
      },
      restartAndroid: () async => throw StateError('Unexpected restart'),
    );

    expect(bkRemoteProfileBlockReason(await controller.load()),
        bkProfileMissingConfiguration);
    expect(requests, [
      {'op': 'profiles'}
    ]);
  });

  test('profile read and switch failures take priority over native readiness',
      () async {
    expect(
        bkRemoteProfileBlockReason(
            profileState(error: 'Server profile selection is invalid')),
        'Server profile selection is invalid');
    expect(bkRemoteProfileBlockReason(profileState(phase: 'testing')),
        bkProfileInterruptedSwitch);
    expect(bkRemoteProfileBlockReason(profileState(restartRequired: true)),
        bkProfileIncompleteSwitch);
    expect(bkRemoteProfileBlockReason({...profileState(), 'ready': null}),
        bkProfileReadError);

    final controller = BkProfileController(
      request: (_) async => {...profileState(), 'phase': 'invalid'},
      restartAndroid: () async => throw StateError('Unexpected restart'),
    );
    await expectLater(controller.load(), throwsStateError);
  });

  test(
      'usable profiles defer to native network status, manual is distinguished',
      () {
    for (final profile in ['bk', 'official', 'manual']) {
      // A usable configuration is not proof of a server connection.
      expect(
          bkRemoteProfileBlockReason(profileState(profile: profile)), isNull);
    }
    expect(
        bkRemoteProfileBlockReason(
            profileState(profile: 'manual', ready: false)),
        'Not configured');
    expect(
        bkRemoteProfileBlockReason(
            profileState(profile: 'official', ready: false)),
        bkProfileReadError);
  });
}
