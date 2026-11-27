import 'dart:async';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../mobile/widgets/dialog.dart' show showServerSettings;
import '../../models/bk_remote_model.dart';
import '../../models/platform_model.dart';
import '../bk_remote_profiles.dart';
import '../bk_remote_account_client.dart';

class BkRemoteProfilesPage extends StatefulWidget {
  const BkRemoteProfilesPage({super.key});

  @override
  State<BkRemoteProfilesPage> createState() => _BkRemoteProfilesPageState();
}

class _BkRemoteProfilesPageState extends State<BkRemoteProfilesPage> {
  late final BkProfileController _controller;
  Map<String, dynamic>? _state;
  String _selected = 'bk';
  String? _message;
  bool _busy = false;
  Timer? _timer;
  static const _labels = {
    'bk': 'BK Remote self-hosted server',
    'official': 'Official public servers',
    'manual': 'Manual self-hosted server',
  };

  @override
  void initState() {
    super.initState();
    _controller = BkProfileController(
      request: bkRemoteNative,
      restartAndroid: () async =>
          await platformFFI.invokeMethod('restart_bk_profile') == true,
    );
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = await _controller.load();
      if (!mounted) return;
      setState(() {
        _state = state;
        _selected = state['profile'] as String;
        if (state['result'] == 'rolled_back') {
          _message = translate('The previous server profile was restored');
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            translate('The server profile selection could not be read'));
      }
    }
  }

  Future<void> _switch({bool recover = false}) async {
    final state = _state;
    if (state == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate(recover
            ? 'Restore the previous server profile'
            : 'Restart and switch server profile')),
        content: Text(translate(
            'Switching ends all current sessions and restarts the application and its service. Each profile keeps its own account, device identity, passwords and connection history. Android screen capture must be authorized again. Windows requires administrator approval.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(translate('Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(translate('Confirm'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    // Keep the current account alive until the native selection actually changes.
    // Native origin/identity checks reject old-profile requests after that change.
    try {
      final restart = await _controller
          .switchTo(_selected, state['generation'] as int, recover: recover);
      if (!mounted) return;
      setState(() {
        _message = translate(restart == 'none'
            ? 'This server profile is already active'
            : 'Restarting to activate the server profile');
        _busy = restart != 'none';
      });
      if (restart == 'automatic') {
        var ticks = 0;
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
          ticks++;
          await _load();
          if (ticks >= 45 && mounted) {
            _timer?.cancel();
            setState(() {
              _busy = false;
              _message = translate(
                  'The switch did not complete. Refresh to inspect the active profile or restore the previous profile.');
            });
          }
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = error is StateError
            ? translate(error.message)
            : error is BkRemoteAccountError
                ? translate(error.message)
                : translate('The server profile switch failed');
      });
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final active = state?['profile'];
    return Scaffold(
      appBar: AppBar(
        title: Text(translate('Server profiles')),
        actions: [
          IconButton(
              tooltip: translate('Refresh'),
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(translate(
              'Profiles keep accounts, device identities, local passwords, favorites, recent connections and address books separate. Switching back restores that profile without copying credentials.')),
          const SizedBox(height: 12),
          for (final profile in _labels.entries)
            RadioListTile<String>(
              value: profile.key,
              groupValue: _selected,
              title: Text(translate(profile.value)),
              subtitle: active == profile.key
                  ? Text(translate('Current profile'))
                  : null,
              onChanged: _busy || state?['can_switch'] != true
                  ? null
                  : (value) => setState(() => _selected = value!),
            ),
          if (state != null) ...[
            if (state['error'] != null)
              Text(translate(state['error'].toString())),
            if (state['phase'] == 'testing')
              Text(translate(
                  'A previous profile switch was interrupted. Restore the previous profile to continue.')),
            if (state['ready'] != true && active == 'bk')
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(translate(
                      'The BK server address and public key are not configured. Use a build with the approved public server settings, import a signed configuration, or select another profile. Public servers will not be used automatically.')),
                ),
              ),
            if (active != 'official')
              ListTile(
                title: Text(translate('ID Server')),
                subtitle: Text(
                    (state['rendezvous'] as String?)?.isNotEmpty == true
                        ? state['rendezvous'].toString()
                        : translate('Not configured')),
              ),
            if (active != 'official')
              ListTile(
                title: Text(translate('API Server')),
                subtitle: Text((state['api'] as String?)?.isNotEmpty == true
                    ? state['api'].toString()
                    : translate('Not configured')),
              ),
            if (active == 'manual' && state['phase'] == 'stable')
              OutlinedButton.icon(
                icon: const Icon(Icons.dns_outlined),
                label: Text(translate('ID/Relay Server')),
                onPressed: _busy
                    ? null
                    : () => showServerSettings(gFFI.dialogManager, (callback) {
                          if (mounted) setState(callback);
                          _load();
                        }),
              ),
            if (active == 'bk')
              Text(translate(
                  'The relay address is assigned by the server. Account access is unavailable until the account API is configured.')),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: Text(translate('Restart and switch server profile')),
              onPressed: _busy ||
                      state['can_switch'] != true ||
                      _selected == active ||
                      state['phase'] != 'stable'
                  ? null
                  : () => _switch(),
            ),
            if (state['rollback_available'] == true)
              TextButton(
                  onPressed: _busy ? null : () => _switch(recover: true),
                  child:
                      Text(translate('Restore the previous server profile'))),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_message!)),
        ],
      ),
    );
  }
}
