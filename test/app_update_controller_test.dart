import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/app_update/app_update_controller.dart';
import 'package:retro_eshop/utils/friendly_error.dart';

import 'helpers/app_update_fakes.dart';

void main() {
  late FakeUpdateService service;
  late FakeInstaller installer;
  late AppUpdateController controller;
  late List<AppUpdateStage> stages;

  setUp(() {
    service = FakeUpdateService();
    installer = FakeInstaller();
    controller = AppUpdateController(service: service, installer: installer);
    stages = [];
    controller.addListener(() {
      if (stages.isEmpty || stages.last != controller.stage) {
        stages.add(controller.stage);
      }
    });
  });

  tearDown(() => controller.dispose());

  group('checking', () {
    test('a higher build number is an update', () async {
      await controller.check();
      expect(stages, [AppUpdateStage.checking, AppUpdateStage.available]);
      expect(controller.release!.build, 16);
      expect(controller.installed!.build, 15);
    });

    test('the same build is up to date', () async {
      service.installedBuildNumber = 16;
      await controller.check();
      expect(controller.stage, AppUpdateStage.upToDate);
      expect(controller.release!.build, 16);
      expect(service.cleared, 1,
          reason: 'the APK of the running build is removed from the cache');
    });

    test('a pending update keeps its download', () async {
      await controller.check();
      expect(controller.stage, AppUpdateStage.available);
      expect(service.cleared, 0);
    });

    test('no published build is up to date', () async {
      service.next = null;
      await controller.check();
      expect(controller.stage, AppUpdateStage.upToDate);
      expect(controller.release, isNull);
    });

    test('a failure shows its reason and can be retried', () async {
      service.latestError = const UserFacingException('Could not reach GitHub: offline');
      await controller.check();
      expect(controller.stage, AppUpdateStage.failed);
      expect(controller.error, 'Could not reach GitHub: offline');

      service.latestError = null;
      await controller.check();
      expect(controller.stage, AppUpdateStage.available);
      expect(controller.error, isNull);
    });
  });

  group('installing', () {
    setUp(() => controller.check());

    test('downloads, then opens Android\'s installer', () async {
      await controller.download();

      expect(stages, [
        AppUpdateStage.checking,
        AppUpdateStage.available,
        AppUpdateStage.downloading,
        AppUpdateStage.readyToInstall,
      ]);
      expect(controller.progress, 1.0);
      expect(installer.installed, [service.apk.path]);
    });

    test('waits for the Android permission, then carries on', () async {
      installer.allowed = false;
      await controller.download();
      expect(controller.stage, AppUpdateStage.needsPermission);
      expect(installer.installed, isEmpty);

      await controller.openInstallPermission();
      expect(installer.permissionPagesOpened, 1);

      // Back from Android's settings without allowing it: nothing changes.
      await controller.recheckPermission();
      expect(controller.stage, AppUpdateStage.needsPermission);

      installer.allowed = true;
      await controller.recheckPermission();
      expect(controller.stage, AppUpdateStage.readyToInstall);
      expect(installer.installed, [service.apk.path]);
    });

    test('the installer can be opened again after the user dismissed it',
        () async {
      await controller.download();
      await controller.install();
      expect(installer.installed, [service.apk.path, service.apk.path]);
      expect(service.downloads, 1, reason: 'the file is not fetched twice');
    });

    test('a failed download shows its reason', () async {
      service.downloadError = const UserFacingException(
          'The downloaded file does not match its published checksum. It was not installed.');
      await controller.download();
      expect(controller.stage, AppUpdateStage.failed);
      expect(controller.error, contains('does not match'));
      expect(installer.installed, isEmpty);
    });

    test('an installer that cannot start shows its reason', () async {
      installer.installError =
          const UserFacingException('Android has no installer that opens this file');
      await controller.download();
      expect(controller.stage, AppUpdateStage.failed);
      expect(controller.error, 'Android has no installer that opens this file');
    });

    test('cancelling a download returns to the offer', () async {
      service.gate = Completer<void>();
      final running = controller.download();
      await Future<void>.delayed(Duration.zero);
      expect(controller.stage, AppUpdateStage.downloading);
      expect(controller.progress, 0.5);

      controller.cancelDownload();
      await running;
      expect(controller.stage, AppUpdateStage.available);
      expect(installer.installed, isEmpty);
    });

    test('a second press while downloading does not start another download',
        () async {
      service.gate = Completer<void>();
      final first = controller.download();
      await Future<void>.delayed(Duration.zero);
      await controller.download();
      service.gate!.complete();
      await first;
      expect(service.downloads, 1);
    });
  });

  test('recheckPermission does nothing outside the permission step', () async {
    await controller.check();
    await controller.recheckPermission();
    expect(controller.stage, AppUpdateStage.available);
    expect(installer.installed, isEmpty);
  });

  test('the fake download honours a cancel token like the real one', () async {
    service.gate = Completer<void>();
    final token = CancelToken();
    final download = service.download(sampleRelease, cancelToken: token);
    token.cancel();
    await expectLater(download, throwsA(isA<DioException>()));
    expect(File(service.apk.path).existsSync(), isFalse);
  });
}
