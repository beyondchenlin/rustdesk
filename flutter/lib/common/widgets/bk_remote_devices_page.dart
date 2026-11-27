import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../common/bk_remote_account_client.dart';
import '../../common/bk_remote_device_time.dart';
import '../../common/bk_remote_native_presence.dart';
import '../../desktop/pages/desktop_home_page.dart' show setPasswordDialog;
import '../../models/bk_remote_model.dart';
import '../../models/platform_model.dart';
import '../../models/user_model.dart';
import '../widgets/login.dart';

class BkRemotePasswordSetup extends StatefulWidget {
  const BkRemotePasswordSetup({super.key});

  @override
  State<BkRemotePasswordSetup> createState() => _BkRemotePasswordSetupState();
}

class _BkRemotePasswordSetupState extends State<BkRemotePasswordSetup> {
  bool _required = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final isSet = await bind.mainGetCommon(key: 'permanent-password-set');
    final mode = await bind.mainGetOption(key: 'approve-mode');
    final method = await bind.mainGetOption(key: 'verification-method');
    if (!mounted) return;
    setState(() => _required = isSet != 'true' &&
        mode == 'password' &&
        method == 'use-permanent-password');
  }

  @override
  Widget build(BuildContext context) {
    if (!_required) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate(
                'Set a permanent password before accepting remote sessions')),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => setPasswordDialog(notEmptyCallback: _refresh),
              icon: const Icon(Icons.key),
              label: Text(translate('Set permanent password')),
            ),
          ],
        ),
      ),
    );
  }
}

class BkRemoteDevicesPage extends StatefulWidget {
  const BkRemoteDevicesPage({super.key});

  @override
  State<BkRemoteDevicesPage> createState() => _BkRemoteDevicesPageState();
}

class _BkRemoteDevicesPageState extends State<BkRemoteDevicesPage> {
  List<Map<String, dynamic>> _devices = [];
  bool _busy = false;
  bool _cached = false;
  String _error = '';
  String _origin = '';
  String _deviceId = '';
  DateTime? _lastSync;
  String _listToken = '';
  int _page = 0;
  static const _pageSize = BkNativePresenceController.maxPeers;
  late final BkNativePresenceController _nativePresence;
  Timer? _nativeTimer;
  Timer? _accountTimer;

  List<Map<String, dynamic>> get _visibleDevices =>
      _devices.skip(_page * _pageSize).take(_pageSize).toList();

  @override
  void initState() {
    super.initState();
    _nativePresence = BkNativePresenceController(
        bridge: (key) => bind.mainGetCommon(key: key));
    _nativePresence.addListener(_presenceChanged);
    _refresh();
    _nativeTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _refreshNative());
    _accountTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted && gFFI.userModel.isLogin) _refresh();
    });
  }

  void _presenceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshNative() async {
    if (!mounted) return;
    final token = _listToken;
    final origin = _origin;
    if (_cached || token.isEmpty || origin.isEmpty || _devices.isEmpty) {
      _nativePresence.reset();
      return;
    }
    String actualOrigin;
    try {
      actualOrigin =
          (await bind.mainGetApiServer()).replaceFirst(RegExp(r'/+$'), '');
    } catch (_) {
      if (mounted) _nativePresence.reset();
      return;
    }
    if (!mounted) return;
    if (token != _listToken ||
        token != bind.mainGetLocalOption(key: 'access_token') ||
        origin != _origin ||
        origin != actualOrigin) {
      _nativePresence.reset();
      setState(() {
        _devices = [];
        _listToken = '';
        _cached = true;
      });
      return;
    }
    await _nativePresence.refresh(
        _visibleDevices.map((device) => device['id'].toString()).toList(),
        accountOrigin: origin);
    if (!mounted) return;
    if (token != _listToken ||
        token != bind.mainGetLocalOption(key: 'access_token') ||
        origin != _origin) {
      _nativePresence.reset();
    }
  }

  void _changePage(int page) {
    if (_busy) return;
    setState(() => _page = page);
    _refreshNative();
  }

  @override
  void dispose() {
    _nativeTimer?.cancel();
    _accountTimer?.cancel();
    _nativePresence.removeListener(_presenceChanged);
    _nativePresence.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    BkRemoteAccountClient? account;
    try {
      account = await openBkRemoteAccount();
      final devices = await account.devices();
      await account.checkSession();
      final now = DateTime.now();
      final user = gFFI.userModel.userName.value;
      await bind.mainSetLocalOption(
          key: bkRemoteCacheKey(account.origin, user),
          value: jsonEncode({
            'synced_at': now.toUtc().toIso8601String(),
            'devices': devices
          }));
      await account.checkSession();
      if (!mounted) return;
      if (_listToken != account.token || _origin != account.origin) {
        _nativePresence.reset();
      }
      setState(() {
        _devices = devices;
        _page = _page
            .clamp(0, devices.isEmpty ? 0 : (devices.length - 1) ~/ _pageSize)
            .toInt();
        _listToken = account!.token;
        _origin = account.origin;
        _deviceId = account.identity['id'].toString();
        _lastSync = now;
        _cached = false;
      });
      _refreshNative();
    } catch (error) {
      if (!mounted) return;
      final origin =
          (await bind.mainGetApiServer()).replaceFirst(RegExp(r'/+$'), '');
      final user = gFFI.userModel.userName.value;
      var devices = <Map<String, dynamic>>[];
      DateTime? synced;
      if (user.isNotEmpty &&
          bind.mainGetLocalOption(key: 'access_token').isNotEmpty &&
          !(error is BkRemoteAccountError && error.status == 401)) {
        try {
          final raw =
              bind.mainGetLocalOption(key: bkRemoteCacheKey(origin, user));
          if (raw.isNotEmpty) {
            final cache = jsonDecode(raw);
            devices = (cache['devices'] as List).cast<Map<String, dynamic>>();
            synced =
                DateTime.tryParse(cache['synced_at'].toString())?.toLocal();
          }
        } catch (_) {
          devices = [];
        }
      }
      if (!mounted) return;
      _nativePresence.reset();
      setState(() {
        _devices = devices;
        _page = 0;
        _listToken = '';
        _origin = origin;
        _deviceId = '';
        _lastSync = synced;
        _cached = true;
        _error = _safeMessage(error);
      });
    } finally {
      account?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _safeMessage(Object error) => translate(error is BkRemoteAccountError
      ? error.message
      : 'The team device request failed');

  Future<void> _operate(
      Future<void> Function(BkRemoteAccountClient) operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    BkRemoteAccountClient? account;
    try {
      account = await openBkRemoteAccount();
      await operation(account);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _safeMessage(error);
          if (error is BkRemoteAccountError && error.status == 401) {
            _devices = [];
            _listToken = '';
            _nativePresence.reset();
            _deviceId = '';
            _lastSync = null;
            _cached = false;
          }
        });
      }
    } finally {
      account?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enroll({String? recoverDeviceId}) async {
    var succeeded = false;
    await _operate((account) async {
      await account.enroll(recoverDeviceId: recoverDeviceId);
      succeeded = true;
      bkRemotePresence.start();
      await UserModel.updateOtherModels();
    });
    if (succeeded && mounted) await _refresh();
  }

  Future<void> _connect(String id) async {
    await _operate((account) async {
      final current = await account.devices();
      if (!current.any((device) => device['id'] == id)) {
        throw const BkRemoteAccountError(
            'Device registration or permission is required');
      }
      await account.checkSession();
      if (mounted) await connect(context, id);
    });
  }

  Future<void> _revoke(Map<String, dynamic> device) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate('Revoke account access')),
        content: Text(translate(
            'This removes account access. The device password and native remote service remain unchanged.')),
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
    if (approved != true || !mounted) return;
    var succeeded = false;
    await _operate((account) async {
      await account.revoke(device['id'].toString());
      succeeded = true;
    });
    if (succeeded && mounted) await _refresh();
  }

  Future<void> _release(Map<String, dynamic> device) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate('Release device ownership')),
        content: Text(translate(
            'This releases team ownership. Another account must prove possession of this device before registering it. The local password and remote service remain unchanged.')),
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
    if (approved != true || !mounted) return;
    var succeeded = false;
    await _operate((account) async {
      await account.release(device['id'].toString());
      succeeded = true;
    });
    if (succeeded && mounted) await _refresh();
  }

  Future<void> _grant(Map<String, dynamic> device) async {
    final controller = TextEditingController();
    final selection = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate('Manage member access')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration:
              InputDecoration(labelText: translate('Member account ID')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(translate('Cancel'))),
          for (final revoke in [true, false])
            TextButton(
                onPressed: () {
                  final userId = int.tryParse(controller.text.trim());
                  if (userId != null && userId > 0) {
                    Navigator.pop(
                        context, {'user_id': userId, 'revoke': revoke});
                  }
                },
                child:
                    Text(translate(revoke ? 'Revoke access' : 'Grant access'))),
        ],
      ),
    );
    controller.dispose();
    if (selection == null || !mounted) return;
    await _operate((account) => account.grant(
          device['id'].toString(),
          selection['user_id'] as int,
          revoke: selection['revoke'] as bool,
        ));
  }

  Future<void> _recover() async {
    final controller = TextEditingController();
    final oldId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate('Recover a reinstalled device')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(translate(
              'Only the previous owner can replace an old device registration after proving the new device identity.')),
          TextField(
              controller: controller,
              decoration:
                  InputDecoration(labelText: translate('Previous device ID'))),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(translate('Cancel'))),
          FilledButton(
              onPressed: () {
                final id = controller.text.trim();
                if (id.isNotEmpty) Navigator.pop(context, id);
              },
              child: Text(translate('Confirm'))),
        ],
      ),
    );
    controller.dispose();
    if (oldId != null && mounted) await _enroll(recoverDeviceId: oldId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(translate('Team devices')),
        actions: [
          IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: translate('Refresh'),
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const BkRemotePasswordSetup(),
            Text(translate(
                'Team access does not share device passwords. First connections use the target device password.')),
            if (_origin.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_origin)),
            if (!gFFI.userModel.isLogin)
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        await loginDialog();
                        if (mounted) await _refresh();
                      },
                icon: const Icon(Icons.login),
                label: Text(translate('Login')),
              )
            else
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _enroll,
                  icon: const Icon(Icons.add_to_photos_outlined),
                  label: Text(translate('Register this device')),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _recover,
                  child: Text(translate('Recover a reinstalled device')),
                ),
              ]),
            if (_busy) const LinearProgressIndicator(),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_cached && _devices.isNotEmpty)
              Text(translate(
                  'Cached devices. Refresh succeeds before team connections are enabled.')),
            if (_lastSync != null)
              Text(
                  '${translate('Last synchronized')}: ${formatBkRemoteDeviceTime(_lastSync)}'),
            Text(translate(
                'Native online status confirms registration, not screen capture or input permission.')),
            const SizedBox(height: 12),
            if (_devices.length > _pageSize)
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                    onPressed: _busy || _page == 0
                        ? null
                        : () => _changePage(_page - 1),
                    tooltip: translate('Previous page'),
                    icon: const Icon(Icons.chevron_left)),
                Text(((_page * _pageSize) + 1).toString() +
                    '-' +
                    ((_page + 1) * _pageSize)
                        .clamp(0, _devices.length)
                        .toString() +
                    ' / ' +
                    _devices.length.toString()),
                IconButton(
                    onPressed:
                        _busy || (_page + 1) * _pageSize >= _devices.length
                            ? null
                            : () => _changePage(_page + 1),
                    tooltip: translate('Next page'),
                    icon: const Icon(Icons.chevron_right)),
              ]),
            if (_devices.isEmpty && !_busy)
              Text(translate('No authorized team devices')),
            for (final device in _visibleDevices) _deviceCard(device),
          ]),
        ),
      ),
    );
  }

  Widget _deviceCard(Map<String, dynamic> device) {
    final id = device['id'].toString();
    final info = device['info'] is Map ? device['info'] as Map : {};
    final name = (info['device_name'] ?? '').toString();
    final group = (device['device_group_name'] ?? '').toString();
    final heartbeatStatus = _cached || device['status'] == null
        ? translate('Unknown')
        : device['status'] == 1
            ? translate('Online')
            : translate('Offline');
    final lastOnline = parseBkRemoteAccountTime(device['last_online_time']);
    final nativeState = _cached
        ? BkNativeRegistrationState.unknown
        : _nativePresence.stateFor(id);
    final nativeStatus = translate(switch (nativeState) {
      BkNativeRegistrationState.online => 'Online',
      BkNativeRegistrationState.offline => 'Offline',
      BkNativeRegistrationState.unknown => 'Unknown',
    });
    final attempted = _nativePresence.attemptedAtFor(id);
    final observed = _nativePresence.observedAtFor(id);
    final lastObservedOnline = _nativePresence.lastOnlineAtFor(id);
    return Card(
      child: ListTile(
        leading: Icon(
            info['os'] == 'android' ? Icons.phone_android : Icons.computer),
        title: Text(name.isEmpty ? id : name),
        subtitle: Text([
          id,
          translate('Native registration') + ': ' + nativeStatus,
          translate('Account heartbeat') + ': ' + heartbeatStatus,
          if (attempted != null)
            '${translate('Last query attempt')}: ${formatBkRemoteDeviceTime(attempted)}',
          if (observed != null)
            translate('Last verified here') +
                ': ' +
                formatBkRemoteDeviceTime(observed),
          if (lastObservedOnline != null)
            translate('Last seen online here') +
                ': ' +
                formatBkRemoteDeviceTime(lastObservedOnline),
          if (group.isNotEmpty) group,
          '${translate('Last account heartbeat')}: ${formatBkRemoteDeviceTime(lastOnline)}',
        ].join(' · ')),
        isThreeLine: false,
        trailing: Wrap(children: [
          IconButton(
              onPressed: _busy || _cached || id == _deviceId
                  ? null
                  : () => _connect(id),
              tooltip: translate('Connect'),
              icon: const Icon(Icons.open_in_new)),
          if (device['can_manage'] == true)
            PopupMenuButton<String>(
              enabled: !_busy && !_cached,
              onSelected: (action) {
                if (action == 'revoke') _revoke(device);
                if (action == 'release') _release(device);
                if (action == 'grant') _grant(device);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'grant',
                    child: Text(translate('Manage member access'))),
                PopupMenuItem(
                    value: 'revoke',
                    child: Text(translate('Revoke account access'))),
                PopupMenuItem(
                    value: 'release',
                    child: Text(translate('Release device ownership'))),
              ],
            ),
        ]),
      ),
    );
  }
}
