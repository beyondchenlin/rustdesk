import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart' show CommonConfirmDialog;
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/mobile/pages/server_page.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  int stopped = 0;
  int started = 0;
  String stopOption = '';
  void Function()? beforeStart;
  Completer<void>? startGate;
  Completer<void>? stopGate;

  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;

  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';

  @override
  bool isDisableSettings({dynamic hint}) => false;

  @override
  bool isOutgoingOnly({dynamic hint}) => false;

  @override
  String mainGetBuildinOption({required String key, dynamic hint}) => '';

  @override
  Future<void> mainStartService({dynamic hint}) async {
    beforeStart?.call();
    await startGate?.future;
    started++;
    stopOption = '';
  }

  @override
  String mainGetOptionSync({required String key, dynamic hint}) =>
      key == 'stop-service' ? stopOption : '';

  @override
  Future<void> mainStopService({dynamic hint}) async {
    await stopGate?.future;
    stopped++;
    stopOption = 'Y';
  }
}

class _Events extends Fake implements FfiModel {
  @override
  updateEventListener(SessionID sessionId, String peerId) {}
}

class _Dialogs extends Fake implements OverlayDialogManager {
  int shown = 0;
  Completer<bool?>? pending;
  DialogBuilder? pendingBuilder;

  @override
  Future<T?> show<T>(DialogBuilder builder,
      {bool clickMaskDismiss = false,
      bool backDismiss = false,
      String? tag,
      bool useAnimation = true,
      bool forceGlobal = false}) {
    shown++;
    pendingBuilder = builder;
    pending = Completer<bool?>();
    return pending!.future.then((value) => value as T?);
  }
}

class _Session extends Fake implements FFI {
  final calls = <String>[];
  final stopArguments = <dynamic>[];
  FMethod? nativeHandler;
  @override
  final _Dialogs dialogManager = _Dialogs();
  @override
  late ServerModel serverModel;

  @override
  void setMethodCallHandler(FMethod callback) => nativeHandler = callback;

  bool failStop = false;
  bool failManualStop = false;
  Completer<void>? stopGate;
  void Function()? onStop;
  void Function()? onCheck;

  @override
  final sessionId = Uuid().v4obj();

  @override
  final ffiModel = _Events();

  @override
  Future<bool> invokeMethod(String method, [dynamic arguments]) async {
    calls.add(method);
    if (method == 'stop_service') {
      stopArguments.add(arguments);
      await stopGate?.future;
      if (failStop || (failManualStop && arguments == true)) {
        throw PlatformException(code: 'USER_STOP_PERSIST_FAILED');
      }
      onStop?.call();
    }
    if (method == 'check_service') onCheck?.call();
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Binding binding;
  late _Session session;
  late ServerModel model;

  setUp(() async {
    isTest = true;
    binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    session = _Session();
    model = ServerModel(WeakReference(session));
    session.serverModel = model;
    await model.startService();
    // A completed initial authorization followed by projection revocation leaves
    // a live receiver, which is the starting state of the existing regressions.
    model.changeStatue('media', true);
    model.changeStatue('media', false);
    session.calls.clear();
  });

  tearDown(() {
    model.dispose();
    isTest = false;
  });

  void recreateModel() {
    model.dispose();
    model = ServerModel(WeakReference(session));
    session.serverModel = model;
    session.calls.clear();
  }

  Future<void> pumpPendingConfirmation(WidgetTester tester) async {
    final builder = session.dialogManager.pendingBuilder!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          return builder(setState, ([dynamic value]) {
            if (!session.dialogManager.pending!.isCompleted) {
              session.dialogManager.pending!.complete(value as bool?);
            }
          }, context);
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('stop confirmation defaults to cancel for Enter and numpad Enter',
      (tester) async {
    for (final key in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
    ]) {
      final confirmation = model.toggleService();
      await pumpPendingConfirmation(tester);
      await tester.sendKeyEvent(key);
      await tester.pump();
      await confirmation;
      expect(model.isStart, isTrue);
      expect(binding.stopped, 0);
      expect(session.stopArguments, isEmpty);
      expect(session.calls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('explicit stop confirmation button still persists user intent',
      (tester) async {
    final confirmation = model.toggleService();
    await pumpPendingConfirmation(tester);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await confirmation;
    expect(model.isStart, isFalse);
    expect(binding.stopped, 1);
    expect(session.stopArguments, [true]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop stop confirmation cancels both Enter keys by default',
      (tester) async {
    var confirmed = 0;
    for (final key in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
    ]) {
      CommonConfirmDialog(
          session.dialogManager, 'Stop service?', () => confirmed++,
          defaultCancel: true);
      await pumpPendingConfirmation(tester);
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(session.dialogManager.pending!.isCompleted, isTrue);
      expect(confirmed, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('desktop stop confirmation accepts an explicit confirm click',
      (tester) async {
    var confirmed = 0;
    CommonConfirmDialog(
        session.dialogManager, 'Stop service?', () => confirmed++,
        defaultCancel: true);
    await pumpPendingConfirmation(tester);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(confirmed, 1);
    expect(session.dialogManager.pending!.isCompleted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('other desktop confirmations retain their default Enter action',
      (tester) async {
    var confirmed = 0;
    CommonConfirmDialog(
        session.dialogManager, 'Existing confirmation', () => confirmed++);
    await pumpPendingConfirmation(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(confirmed, 1);
    expect(session.dialogManager.pending!.isCompleted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('rebound receiver ignores a late unowned native projection cancellation',
      () async {
    recreateModel();
    androidChannelInit(ffi: session);
    session.nativeHandler!(
        'on_state_changed', {'name': 'service', 'value': 'true'});
    session.nativeHandler!(
        'on_state_changed', {'name': 'media', 'value': 'false'});
    session.nativeHandler!('on_media_projection_canceled', null);
    await Future<void>.delayed(Duration.zero);
    expect(model.isStart, isTrue);
    expect(model.mediaOk, isFalse);
    expect(binding.stopped, 0);
    expect(session.calls, isEmpty);
  });

  test('completed startup ignores a later unowned cancellation', () async {
    await model.onMediaProjectionCanceled();
    expect(model.isStart, isTrue);
    expect(binding.stopped, 0);
    expect(session.calls, isEmpty);
  });

  test('first startup keeps consent ownership across early service state events',
      () async {
    recreateModel();
    session.onCheck = () => model.changeStatue('service', false);
    await model.startService();
    await model.toggleScreenCapture();
    expect(session.calls, ['init_service', 'check_service']);
    expect(session.dialogManager.shown, 0);
    model.changeStatue('service', true);
    model.changeStatue('media', false);
    await model.onMediaProjectionCanceled();
    await model.onMediaProjectionCanceled();
    expect(model.isStart, isFalse);
    expect(binding.stopped, 1);
    expect(session.stopArguments, [false]);
    expect(session.calls,
        ['init_service', 'check_service', 'stop_service', 'check_service']);
  });

  test('startup cancellation cleans up after an in-flight native enable',
      () async {
    recreateModel();
    binding.startGate = Completer<void>();
    final starting = model.startService();
    await Future<void>.delayed(Duration.zero);
    final cancellation = model.onMediaProjectionCanceled();
    await Future<void>.delayed(Duration.zero);
    final stoppedBeforeEnableCompleted = binding.stopped;
    binding.startGate!.complete();
    await starting;
    await cancellation;
    expect(stoppedBeforeEnableCompleted, 0);
    expect(binding.stopped, 1);
    expect(binding.stopOption, 'Y');
    expect(model.isStart, isFalse);
    expect(session.stopArguments, [false]);
  });

  test('native stop event waits for confirmation and cancellation keeps service',
      () async {
    androidChannelInit(ffi: session);
    session.nativeHandler!('stop_service', null);
    expect(session.dialogManager.shown, 1);
    expect(session.calls, isEmpty);
    expect(binding.stopped, 0);
    session.dialogManager.pending!.complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(model.isStart, isTrue);
    expect(session.calls, isEmpty);
    expect(binding.stopped, 0);
  });

  test('confirmed native stop event persists the explicit user decision',
      () async {
    androidChannelInit(ffi: session);
    session.nativeHandler!('stop_service', null);
    expect(session.dialogManager.shown, 1);
    expect(session.calls, isEmpty);
    session.dialogManager.pending!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(model.isStart, isFalse);
    expect(binding.stopped, 1);
    expect(session.stopArguments, [true]);
    expect(session.calls, ['stop_service', 'check_service']);
  });

  test('native stop event for a stopped receiver never starts it', () async {
    model.changeStatue('service', false);
    final startedBefore = binding.started;
    androidChannelInit(ffi: session);
    session.nativeHandler!('stop_service', null);
    await Future<void>.delayed(Duration.zero);
    expect(session.dialogManager.shown, 0);
    expect(model.isStart, isFalse);
    expect(binding.started, startedBefore);
    expect(binding.stopped, 0);
    expect(session.calls, isEmpty);
  });

  test('confirmed manual stop wins over an in-flight native enable', () async {
    recreateModel();
    binding.startGate = Completer<void>();
    final starting = model.startService();
    await Future<void>.delayed(Duration.zero);
    androidChannelInit(ffi: session);
    session.nativeHandler!('stop_service', null);
    expect(session.dialogManager.shown, 1);
    session.dialogManager.pending!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(session.stopArguments, [true]);
    final stoppedBeforeEnableCompleted = binding.stopped;
    binding.startGate!.complete();
    await starting;
    await Future<void>.delayed(Duration.zero);
    expect(stoppedBeforeEnableCompleted, 0);
    expect(binding.stopped, 1);
    expect(binding.stopOption, 'Y');
    expect(model.isStart, isFalse);
  });

  test('failed manual stop preserves a pending first-start request', () async {
    recreateModel();
    binding.startGate = Completer<void>();
    final starting = model.startService();
    await Future<void>.delayed(Duration.zero);
    session.failStop = true;
    await expectLater(
        model.stopService(userInitiated: true), throwsA(isA<PlatformException>()));
    expect(model.isStart, isTrue);
    expect(binding.stopped, 0);
    binding.startGate!.complete();
    await starting;
    expect(binding.stopOption, '');
    expect(binding.stopped, 0);
    session.failStop = false;
    // The failed persistence did not discard consent ownership: a later
    // cancellation must still clean up this model's own first startup.
    await model.onMediaProjectionCanceled();
    expect(binding.stopped, 1);
    expect(model.isStart, isFalse);
    expect(session.stopArguments, [true, false]);
  });

  test('in-flight stopping rejects new consent and coalesces duplicate stops',
      () async {
    session.stopGate = Completer<void>();
    binding.stopGate = Completer<void>();
    final stopping = model.stopService(userInitiated: true);
    await Future<void>.delayed(Duration.zero);
    final duplicate = model.stopService(userInitiated: true);
    expect(identical(stopping, duplicate), isTrue);
    await model.toggleService();
    await model.startService();
    await model.toggleScreenCapture();
    expect(session.dialogManager.shown, 0);
    expect(session.calls, ['stop_service']);
    expect(binding.started, 1);
    expect(binding.stopped, 0);

    session.stopGate!.complete();
    await Future<void>.delayed(Duration.zero);
    await model.toggleService();
    await model.startService();
    await model.toggleScreenCapture();
    expect(session.calls, ['stop_service']);
    expect(binding.started, 1);
    expect(binding.stopped, 0);

    binding.stopGate!.complete();
    await Future.wait([stopping, duplicate]);
    expect(binding.stopped, 1);
    expect(session.stopArguments, [true]);
    expect(model.isStart, isFalse);
    expect(binding.started, 1); // No rejected request automatically restarts.
    await model.startService();
    expect(binding.started, 2); // A later explicit start is permitted.
    expect(session.calls,
        ['stop_service', 'check_service', 'init_service', 'check_service']);
  });

  test('failed stopping shares its error and releases the consent guard',
      () async {
    session.stopGate = Completer<void>();
    session.failStop = true;
    final stopping = model.stopService(userInitiated: true);
    final duplicate = model.stopService(userInitiated: true);
    expect(identical(stopping, duplicate), isTrue);
    final firstFailure =
        expectLater(stopping, throwsA(isA<PlatformException>()));
    final duplicateFailure =
        expectLater(duplicate, throwsA(isA<PlatformException>()));
    await model.startService();
    await model.toggleScreenCapture();
    await model.toggleService();
    expect(session.calls, ['stop_service']);
    expect(session.dialogManager.shown, 0);
    session.stopGate!.complete();
    await Future.wait([firstFailure, duplicateFailure]);
    expect(model.isStart, isTrue);
    expect(binding.stopped, 0);
    expect(binding.started, 1);

    session.failStop = false;
    session.stopGate = null;
    await model.toggleScreenCapture();
    expect(session.calls, ['stop_service', 'init_service']);
    await model.onMediaProjectionCanceled();
    await model.stopService(userInitiated: true);
    expect(binding.stopped, 1);
    expect(session.stopArguments, [true, true]);
  });

  test('late confirmation during automatic cleanup retains manual stop intent',
      () async {
    final confirmation = model.toggleService();
    expect(session.dialogManager.shown, 1);
    binding.stopGate = Completer<void>();
    final cleanup = model.stopService();
    await Future<void>.delayed(Duration.zero);
    expect(session.stopArguments, [false]);
    session.dialogManager.pending!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(binding.stopped, 0);
    binding.stopGate!.complete();
    await cleanup;
    await confirmation;
    expect(binding.stopped, 1);
    expect(session.stopArguments, [false, true]);
    expect(model.isStart, isFalse);
  });

  test('failed late manual persistence does not restore an already stopped service',
      () async {
    recreateModel();
    await model.startService();
    session.stopGate = Completer<void>();
    session.failManualStop = true;
    session.onStop = () => model.changeStatue('service', false);
    final cleanup = model.onMediaProjectionCanceled();
    await Future<void>.delayed(Duration.zero);
    final manual = model.stopService(userInitiated: true);
    final cleanupFailure =
        expectLater(cleanup, throwsA(isA<PlatformException>()));
    final manualFailure =
        expectLater(manual, throwsA(isA<PlatformException>()));
    session.stopGate!.complete();
    await Future.wait([cleanupFailure, manualFailure]);
    expect(session.stopArguments, [false, true]);
    expect(model.isStart, isFalse);
    expect(binding.stopped, 1);
    expect(binding.stopOption, 'Y');
    expect(binding.started, 2);

    session.failManualStop = false;
    await model.startService();
    expect(binding.started, 3);
  });

  test('failed manual stop keeps the receiver and sessions running', () async {
    session.failStop = true;
    await expectLater(
        model.stopService(userInitiated: true), throwsA(isA<PlatformException>()));
    expect(model.isStart, isTrue);
    expect(binding.stopped, 0);
    expect(session.calls, ['stop_service']);
  });

  test('turning projection off leaves the receiver running', () async {
    model.changeStatue('media', true);
    await model.toggleScreenCapture();
    expect(session.calls, ['stop_screen_capture']);
    expect(model.isStart, isTrue);
    expect(binding.stopped, 0);
    // Permission state changes only when the OS reports its actual state.
    expect(model.mediaOk, isTrue);
    model.changeStatue('media', false);
    expect(model.mediaOk, isFalse);
  });

  test('startup reconciles an early bind event after enabling the receiver',
      () async {
    binding.stopOption = 'Y';
    binding.beforeStart = () => model.changeStatue('service', true);
    session.onCheck = () => model.changeStatue('service', true);
    await model.startService();
    expect(model.isStart, isTrue);
    expect(session.calls, ['init_service', 'check_service']);
  });

  test('stopping reconciles an alive event after disabling the receiver',
      () async {
    session.onStop = () => model.changeStatue('service', true);
    session.onCheck = () => model.changeStatue('service', true);
    await model.stopService(userInitiated: true);
    expect(model.isStart, isFalse);
    expect(binding.stopOption, 'Y');
    expect(binding.stopped, 1);
    expect(session.calls, ['stop_service', 'check_service']);
  });

  test('service recovery keeps projection and receiver states separate', () {
    model.changeStatue('service', false);
    expect(model.isStart, isFalse);
    model.changeStatue('service', true);
    expect(model.isStart, isTrue);
    expect(model.mediaOk, isFalse);
    expect(binding.started, 1);
  });

  test('a stopped receiver is not re-enabled by a projection event', () {
    binding.stopOption = 'Y';
    model.changeStatue('service', true);
    expect(model.isStart, isFalse);
    model.changeStatue('media', true);
    expect(model.isStart, isFalse);
    expect(model.mediaOk, isTrue);
    expect(binding.started, 1);
  });

  test('canceling a projection-only request preserves the receiver', () async {
    await model.toggleScreenCapture();
    await model.onMediaProjectionCanceled();
    expect(model.isStart, isTrue);
    expect(model.mediaOk, isFalse);
    expect(binding.stopped, 0);
    expect(session.calls, ['init_service']);
    await model.toggleScreenCapture();
    expect(session.calls, ['init_service', 'init_service']);
  });

  test('repeated projection requests wait for the pending consent', () async {
    await model.toggleScreenCapture();
    await model.toggleScreenCapture();
    expect(session.calls, ['init_service']);
    expect(model.mediaOk, isFalse);
  });

  test('restoring projection requests consent without faking authorization',
      () async {
    await model.toggleScreenCapture();
    expect(session.calls, ['init_service']);
    expect(model.isStart, isTrue);
    expect(model.mediaOk, isFalse);
    expect(binding.stopped, 0);
  });
}
