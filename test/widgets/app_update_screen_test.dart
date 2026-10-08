import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/app_update/app_update_controller.dart';
import 'package:retro_eshop/features/app_update/app_update_screen.dart';
import 'package:retro_eshop/utils/friendly_error.dart';

import '../helpers/app_update_fakes.dart';
import '../helpers/romdrop_harness.dart';

const _a = LogicalKeyboardKey.gameButtonA;
const _x = LogicalKeyboardKey.gameButtonX;
const _down = LogicalKeyboardKey.arrowDown;

void main() {
  late FakeUpdateService service;
  late FakeInstaller installer;
  late AppUpdateController controller;

  setUp(() {
    service = FakeUpdateService();
    installer = FakeInstaller();
    controller = AppUpdateController(service: service, installer: installer);
  });

  Future<void> open(WidgetTester tester) async {
    final harness = await RomDropHarness.create(connected: false);
    addTearDown(controller.dispose);
    await harness.pump(tester, AppUpdateScreen(controller: controller));
  }

  testWidgets('offers a newer build with what changed in it', (tester) async {
    await open(tester);

    expect(find.text('App update'), findsOneWidget);
    expect(find.text('Installed: 1.7.0 (build 15)'), findsOneWidget);
    expect(find.text('Download and install build 16'), findsOneWidget);
    expect(find.textContaining('published 8 Oct 2026'), findsOneWidget);
    expect(find.textContaining('Save folder games as one .zip'), findsOneWidget);
    expect(installer.installed, isEmpty, reason: 'nothing starts by itself');
  });

  testWidgets('A downloads the build and opens Android\'s installer',
      (tester) async {
    await open(tester);
    await press(tester, _a);

    expect(service.downloads, 1);
    expect(installer.installed, [service.apk.path]);
    expect(find.text('build 16 is downloaded and verified'), findsOneWidget);

    // The user dismissed Android's dialog: A opens it again.
    await press(tester, _a);
    expect(installer.installed, hasLength(2));
    expect(service.downloads, 1);
  });

  testWidgets('says so when the installed build is the newest', (tester) async {
    service.installedBuildNumber = 16;
    await open(tester);

    expect(find.text('This is the latest build'), findsOneWidget);
    expect(find.text('Download and install build 16'), findsNothing);
    expect(find.text('Check again'), findsOneWidget);
  });

  testWidgets('shows progress, and X cancels the download', (tester) async {
    service.gate = Completer<void>();
    await open(tester);
    await tester.sendKeyEvent(_a);
    await tester.pump();
    await tester.pump();

    expect(find.text('Downloading build 16'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await press(tester, _x);
    expect(find.text('Download and install build 16'), findsOneWidget);
    expect(installer.installed, isEmpty);
  });

  testWidgets('asks for the Android permission and carries on afterwards',
      (tester) async {
    installer.allowed = false;
    await open(tester);
    await press(tester, _a);

    expect(find.text('Android needs your permission first'), findsOneWidget);
    expect(installer.installed, isEmpty);

    await press(tester, _a); // Open Android settings
    expect(installer.permissionPagesOpened, 1);

    // The user allows it there and comes back to the app.
    installer.allowed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(installer.installed, [service.apk.path]);
    expect(find.text('build 16 is downloaded and verified'), findsOneWidget);
  });

  testWidgets('the second row installs without reopening settings',
      (tester) async {
    installer.allowed = false;
    await open(tester);
    await press(tester, _a);
    installer.allowed = true;

    await press(tester, _down);
    await press(tester, _a); // Install build 16
    expect(installer.permissionPagesOpened, 0);
    expect(installer.installed, [service.apk.path]);
  });

  testWidgets('a failure shows its reason and A tries again', (tester) async {
    service.latestError =
        const UserFacingException('Could not reach GitHub: no connection');
    await open(tester);

    expect(find.text('The update did not go through'), findsOneWidget);
    expect(find.text('Could not reach GitHub: no connection'), findsOneWidget);

    service.latestError = null;
    await press(tester, _a);
    expect(find.text('Download and install build 16'), findsOneWidget);
  });
}
