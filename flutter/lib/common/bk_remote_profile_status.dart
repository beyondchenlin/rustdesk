const bkProfileReadError = 'The server profile selection could not be read';
const bkProfileMissingConfiguration =
    'The BK server address and public key are not configured. Use a build with the approved public server settings, import a signed configuration, or select another profile. Public servers will not be used automatically.';
const bkProfileInterruptedSwitch =
    'A previous profile switch was interrupted. Restore the previous profile to continue.';
const bkProfileIncompleteSwitch =
    'The switch did not complete. Refresh to inspect the active profile or restore the previous profile.';

/// The profile controller validates the selection before this check.
/// A null result only means configuration is usable; network readiness still
/// comes from the native connection status.
String? bkRemoteProfileBlockReason(Map<String, dynamic> state) {
  final error = state['error'];
  if (error is String && error.isNotEmpty) return error;
  if (error != null && error != '') return bkProfileReadError;
  if (state['phase'] == 'testing') return bkProfileInterruptedSwitch;
  if (state['restart_required'] == true) return bkProfileIncompleteSwitch;
  if (state['ready'] is! bool || state['restart_required'] is! bool) {
    return bkProfileReadError;
  }
  if (state['ready'] == true) return null;
  switch (state['profile']) {
    case 'bk':
      return bkProfileMissingConfiguration;
    case 'manual':
      return 'Not configured';
    default:
      return bkProfileReadError;
  }
}
