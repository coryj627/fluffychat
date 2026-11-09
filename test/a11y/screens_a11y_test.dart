// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// Accessibility audit of a slice of screens (flutter_a11y_test, layer "runtime"),
// on this fork only: dogfood of https://github.com/coryj627/flutter-a11y.
//
// Pumps the real FluffyChatApp over a Client that talks to the SDK's FakeMatrixApi
// (test/utils/test_client.dart minus vodozemac: without it the client simply runs
// unencrypted, which is enough to render every screen), navigates the real go_router
// to each route and runs the audit battery. Findings are RECORDED, not asserted: the
// RuntimeFindingsSink in test/flutter_test_config.dart writes them to
// .a11y/flutter/runtime-findings.json and `a11y_check_flutter scan` decides, against
// the committed baseline, what fails CI.
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/widgets/fluffy_chat_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_a11y_test/flutter_a11y_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeNotifications extends FlutterLocalNotificationsPlatform {}

Future<Client> _client({required bool loggedIn}) async {
  SharedPreferences.setMockInitialValues({});
  // AppLock writes the pincode through flutter_secure_storage, a plugin with no host
  // under `flutter test`.
  FlutterSecureStorage.setMockInitialValues({});
  FlutterLocalNotificationsPlatform.instance = _FakeNotifications();
  await AppSettings.init(loadWebConfigFile: false);
  final client = Client(
    'FluffyChat a11y audit',
    httpClient: FakeMatrixApi(),
    database: await MatrixSdkDatabase.init(
      'test',
      database: await databaseFactoryFfiNoIsolate.openDatabase(':memory:'),
      sqfliteFactory: databaseFactoryFfiNoIsolate,
    ),
    supportedLoginTypes: {
      AuthenticationTypes.password,
      AuthenticationTypes.sso,
    },
  );
  if (loggedIn) {
    await client.init(
      newHomeserver: Uri.parse('https://fakeServer.notExisting'),
      newDeviceID: 'ABCD1234',
      newDeviceName: 'a11y audit',
      newToken: '1234',
      newUserID: '@test:fakeServer.notExisting',
    );
    // The first sync has run (waitForFirstSync); stop the loop, which against the
    // instant FakeMatrixApi would spin and leave timers pending after the test.
    client.backgroundSync = false;
  }
  return client;
}

/// Clears the two exceptions this harness expects and fails on anything else.
///
/// FluffyChatApp.router is static: a view model of the previous test's app can still
/// complete an async fetch and notify its disposed ChangeNotifier while this app runs.
/// flutter_test routes such an uncaught error through FlutterError.onError and then
/// asserts its own handler saw it, so it cannot be swallowed there: let it through
/// and take it off the binding here. A RenderFlex overflow at a frame the audit did not
/// measure (the timer drain) is not a finding either.
void _dropKnown(WidgetTester tester) {
  final e = tester.takeException();
  if (e == null) return;
  final text = e.toString();
  if (text.contains('was used after being disposed') ||
      text.contains('A RenderFlex overflowed')) {
    return;
  }
  fail('Unexpected exception during the audit: $e');
}

Future<void> _audit(
  WidgetTester tester,
  String screenId, {
  required String location,
  required bool loggedIn,
  Object? Function(Client client)? extra,
  A11yAuditConfig config = const A11yAuditConfig(),
}) async {
  tester.view.devicePixelRatio = 1.0;
  // Phone width on purpose: above FluffyThemes.columnWidth * 2 the shell swaps between
  // TwoColumnLayout and a single column, and the audit's 320 px reflow pass would flip
  // it mid-test, which (as routes.dart warns) renders a navigator twice under one
  // GlobalKey. At 390 px the layout is single-column at every width the audit uses.
  await tester.binding.setSurfaceSize(const Size(390, 844));
  // MediaQuery reads the view, not the surface: without this the app lays out for
  // 800 x 600 (two columns) while the surface is a phone.
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // runAsync: the client's init and the FakeMatrixApi sync use real futures and
  // timers, which never complete under the test's fake async.
  final client = (await tester.runAsync(() => _client(loggedIn: loggedIn)))!;
  // Real futures again: dispose aborts the sync and closes the database.
  addTearDown(() => tester.runAsync(client.dispose));
  // The router is static and still points at the previous test's route: reset it
  // before this app builds, so the first frame is not a deep settings page that the
  // navigation below then has to unwind (duplicate shell GlobalKeys).
  FluffyChatApp.router.go(loggedIn ? '/rooms' : '/home');
  await tester.pumpWidget(
    FluffyChatApp(
      clients: [client],
      store: await SharedPreferences.getInstance(),
      appLockSettings: (pincode: null, useBiometrics: false),
    ),
  );
  // Fixed pumps rather than pumpAndSettle: progress indicators animate indefinitely.
  await tester.pump(const Duration(milliseconds: 200));
  // Step through the ancestors as a user would: jumping straight to a nested route
  // builds two shell navigators with the same GlobalKey in one frame.
  final segments = Uri.parse(location).pathSegments;
  for (var i = 1; i <= segments.length; i++) {
    final step = '/${segments.take(i).join('/')}';
    FluffyChatApp.router.go(
      step,
      extra: step == location ? extra?.call(client) : null,
    );
    await tester.pump(const Duration(milliseconds: 200));
    _dropKnown(tester);
  }
  await tester.pump(const Duration(milliseconds: 500));
  _dropKnown(tester);
  final result = await auditScreen(tester, screenId: screenId, config: config);
  _dropKnown(tester);
  // Let the app's one-shot timers (search cool-down, typing indicators, the
  // cached-password clear at 10 min) fire before the tree is disposed.
  await tester.pump(const Duration(minutes: 11));
  _dropKnown(tester);
  // ignore: avoid_print
  print(
    'a11y $screenId at ${FluffyChatApp.router.routerDelegate.currentConfiguration.uri}: '
    '${result.findings.length} finding(s)',
  );
}

void main() {
  const room = '!726s6s6q:example.com'; // a room of FakeMatrixApi's sync

  group('logged out', () {
    testWidgets('homeserver picker', (tester) async {
      await _audit(tester, 'home', location: '/home', loggedIn: false);
    });
    testWidgets('sign in', (tester) async {
      await _audit(
        tester,
        'home/sign_in',
        location: '/home/sign_in',
        loggedIn: false,
      );
    });
    testWidgets('sign up', (tester) async {
      await _audit(
        tester,
        'home/sign_up',
        location: '/home/sign_up',
        loggedIn: false,
      );
    });
    testWidgets('login (password)', (tester) async {
      await _audit(
        tester,
        'home/login',
        location: '/home/login',
        loggedIn: false,
        extra: (client) => client,
      );
    });
  });

  group('logged in', () {
    for (final (id, path, config) in [
      ('rooms', '/rooms', const A11yAuditConfig()),
      ('rooms/archive', '/rooms/archive', const A11yAuditConfig()),
      (
        'rooms/newprivatechat',
        '/rooms/newprivatechat',
        const A11yAuditConfig(),
      ),
      ('rooms/newgroup', '/rooms/newgroup', const A11yAuditConfig()),
      ('rooms/newspace', '/rooms/newspace', const A11yAuditConfig()),
      ('rooms/chat', '/rooms/$room', const A11yAuditConfig()),
      ('rooms/chat/details', '/rooms/$room/details', const A11yAuditConfig()),
      (
        'rooms/chat/members',
        '/rooms/$room/details/members',
        const A11yAuditConfig(),
      ),
      // access: ChatAccessSettingsController.roomVersion needs the room's m.room.create
      // version, which FakeMatrixApi's room does not carry (null check in the app).
      // permissions: left out. The in-place text-scale pass trips a Flutter framework
      // assertion (_debugRelayoutBoundaryAlreadyMarkedNeedsLayout) under this page's
      // DropdownButtons; ReflowStrategy.rewrapRoot avoids that but re-creates the app
      // and leaves a timer pending at the end of the test.
      ('settings', '/rooms/settings', const A11yAuditConfig()),
      (
        'settings/notifications',
        '/rooms/settings/notifications',
        const A11yAuditConfig(),
      ),
      ('settings/style', '/rooms/settings/style', const A11yAuditConfig()),
      ('settings/devices', '/rooms/settings/devices', const A11yAuditConfig()),
      ('settings/chat', '/rooms/settings/chat', const A11yAuditConfig()),
      (
        'settings/chat/emotes',
        '/rooms/settings/chat/emotes',
        const A11yAuditConfig(),
      ),
      (
        'settings/security',
        '/rooms/settings/security',
        const A11yAuditConfig(),
      ),
      (
        'settings/homeserver',
        '/rooms/settings/homeserver',
        const A11yAuditConfig(),
      ),
    ]) {
      testWidgets(id, (tester) async {
        await _audit(
          tester,
          id,
          location: path,
          loggedIn: true,
          config: config,
        );
      });
    }
  });
}
