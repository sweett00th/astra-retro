import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:retro_eshop/services/app_update_service.dart';

final sampleRelease = AppRelease(
  tag: 'm1-build-16',
  build: 16,
  notes: 'Development build 16 for ARM64 Android tablets.\n\n'
      'To install: in the app, open Settings, About, App update.\n\n'
      'Changes in this build:\n- Save folder games as one .zip',
  // Midday UTC: the same calendar day in every time zone the tests run in.
  publishedAt: DateTime.utc(2026, 10, 8, 12),
  apkUrl: Uri.parse(
      'https://github.com/sweett00th/astra-retro/releases/download/m1-build-16/astra-retro-debug.apk'),
  apkSize: 136 * 1024 * 1024,
  checksumUrl: Uri.parse(
      'https://github.com/sweett00th/astra-retro/releases/download/m1-build-16/astra-retro-debug.apk.sha256'),
);

/// The update service without GitHub: the test decides what is published and
/// how a download ends.
class FakeUpdateService extends AppUpdateService {
  FakeUpdateService();

  int? installedBuildNumber = 15;
  AppRelease? next = sampleRelease;
  Object? latestError;
  Object? downloadError;

  /// When set, a download waits here after reporting half-way.
  Completer<void>? gate;
  int downloads = 0;
  int cleared = 0;

  /// Never written: the fake installer only records its path.
  final apk = File('synthetic-update.apk');

  @override
  Future<InstalledBuild> installed() async =>
      InstalledBuild('1.7.0', installedBuildNumber);

  @override
  Future<void> clearDownloads() async => cleared++;

  @override
  Future<AppRelease?> latest() async {
    if (latestError != null) throw latestError!;
    return next;
  }

  @override
  Future<File> download(
    AppRelease release, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    downloads++;
    onProgress?.call(release.apkSize ~/ 2, release.apkSize);
    final waiting = gate;
    if (waiting != null) {
      await Future.any([
        waiting.future,
        if (cancelToken != null) cancelToken.whenCancel,
      ]);
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    }
    if (downloadError != null) throw downloadError!;
    onProgress?.call(release.apkSize, release.apkSize);
    return apk;
  }
}

class FakeInstaller implements AppInstaller {
  bool allowed = true;
  int permissionPagesOpened = 0;
  Object? installError;
  final installed = <String>[];

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<void> openInstallPermission() async => permissionPagesOpened++;

  @override
  Future<void> install(File apk) async {
    if (installError != null) throw installError!;
    installed.add(apk.path);
  }
}
