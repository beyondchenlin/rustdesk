import 'dart:async';

typedef BkProfileRequest = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> request);

/// All profile mutations are performed by the native process coordinator.
/// A failed Android handoff must restore the old selection before reporting failure.
class BkProfileController {
  final BkProfileRequest request;
  final Future<bool> Function() restartAndroid;

  BkProfileController({required this.request, required this.restartAndroid});

  Future<Map<String, dynamic>> load() async {
    final state = await request({'op': 'profiles'});
    if (!const ['bk', 'official', 'manual'].contains(state['profile']) ||
        state['generation'] is! int ||
        !const ['stable', 'testing'].contains(state['phase'])) {
      throw StateError('The server profile selection could not be read');
    }
    return state;
  }

  Future<String> switchTo(String target, int generation,
      {bool recover = false}) async {
    if (!const ['bk', 'official', 'manual'].contains(target)) {
      throw ArgumentError('Invalid server profile');
    }
    final result = await request({
      'op': 'switch_profile',
      'target': target,
      'generation': generation,
      'recover': recover,
    });
    final restart = result['restart'];
    if (restart == 'none' || restart == 'automatic') return restart as String;
    if (restart != 'android') {
      throw StateError('The server profile restart was not prepared');
    }
    try {
      if (!await restartAndroid()) {
        throw StateError('The application restart was not accepted');
      }
    } catch (_) {
      final restored = await request({'op': 'abort_profile_switch'});
      if (restored['restored'] != true) {
        throw StateError(
            'The restart failed; reopen the server profile page to recover');
      }
      throw StateError(
          'The restart failed; the previous server profile was restored');
    }
    return 'android';
  }
}
