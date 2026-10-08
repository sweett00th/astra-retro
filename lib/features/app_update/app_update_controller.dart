import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../services/app_update_service.dart';
import '../../utils/friendly_error.dart';

enum AppUpdateStage {
  checking,
  upToDate,
  available,
  downloading,

  /// Downloaded and verified, but Android does not let this app install yet.
  needsPermission,

  /// Downloaded and verified; Android's installer has been or can be opened.
  readyToInstall,
  failed,
}

/// Drives the App update screen: look for a newer build, download and verify
/// it, then hand it to Android's installer.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({AppUpdateService? service, AppInstaller? installer})
      : _service = service ?? AppUpdateService(),
        _installer = installer ?? AndroidAppInstaller();

  final AppUpdateService _service;
  final AppInstaller _installer;

  AppUpdateStage stage = AppUpdateStage.checking;
  InstalledBuild? installed;
  AppRelease? release;
  String? error;

  /// 0..1 while downloading.
  double progress = 0;
  int receivedBytes = 0;

  File? _apk;
  CancelToken? _cancel;
  bool _disposed = false;

  Future<void> check() async {
    _set(AppUpdateStage.checking);
    try {
      installed = await _service.installed();
      final latest = await _service.latest();
      release = latest;
      _set(latest != null && _service.isNewer(latest, installed!)
          ? AppUpdateStage.available
          : AppUpdateStage.upToDate);
    } catch (e) {
      _fail(e);
    }
  }

  /// Downloads the available build, then moves on to installing it.
  Future<void> download() async {
    final target = release;
    if (target == null || stage == AppUpdateStage.downloading) return;
    progress = 0;
    receivedBytes = 0;
    final cancel = _cancel = CancelToken();
    _set(AppUpdateStage.downloading);
    try {
      _apk = await _service.download(
        target,
        cancelToken: cancel,
        onProgress: (received, total) {
          receivedBytes = received;
          progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          _notify();
        },
      );
      await install();
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        _set(AppUpdateStage.available);
      } else {
        _fail(e);
      }
    } finally {
      _cancel = null;
    }
  }

  void cancelDownload() => _cancel?.cancel();

  /// Opens Android's installer for the downloaded build. Android asks the
  /// user to confirm; when they do, it replaces and restarts the app.
  Future<void> install() async {
    final apk = _apk;
    if (apk == null) return;
    try {
      if (!await _installer.canInstall()) {
        _set(AppUpdateStage.needsPermission);
        return;
      }
      _set(AppUpdateStage.readyToInstall);
      await _installer.install(apk);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> openInstallPermission() async {
    try {
      await _installer.openInstallPermission();
    } catch (e) {
      _fail(e);
    }
  }

  /// Called when the user comes back from Android's settings: carries on
  /// with the install if they allowed it there.
  Future<void> recheckPermission() async {
    if (stage != AppUpdateStage.needsPermission) return;
    try {
      if (await _installer.canInstall()) await install();
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    error = getUserFriendlyError(e, returnRawOnNoMatch: true);
    _set(AppUpdateStage.failed);
  }

  void _set(AppUpdateStage next) {
    stage = next;
    if (next != AppUpdateStage.failed) error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
