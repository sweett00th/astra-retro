import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/friendly_error.dart';
import 'romdrop/system_file_download_manager.dart' show sha256OfFile;

/// A build of this app published on the fork's Releases page.
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.build,
    required this.notes,
    required this.publishedAt,
    required this.apkUrl,
    required this.apkSize,
    required this.checksumUrl,
  });

  final String tag;

  /// The number the tag ends with (`m1-build-16` is 16). The workflow builds
  /// the APK with the same number as its Android version code, so it orders
  /// builds the way Android does.
  final int? build;
  final String notes;
  final DateTime? publishedAt;
  final Uri apkUrl;
  final int apkSize;

  /// The `.sha256` file published next to the APK.
  final Uri? checksumUrl;

  String get label => build == null ? tag : 'build $build';
}

/// The build that is running.
class InstalledBuild {
  const InstalledBuild(this.version, this.build);
  final String version;
  final int? build;
}

/// Passes a downloaded update to Android, which asks the user and installs it.
abstract class AppInstaller {
  /// Whether Android lets this app start an install ("Install unknown apps").
  Future<bool> canInstall();

  /// Opens the Android page where the user allows that.
  Future<void> openInstallPermission();

  Future<void> install(File apk);
}

class AndroidAppInstaller implements AppInstaller {
  static const _channel = MethodChannel('com.retro.rshop/app_update');

  @override
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<void> openInstallPermission() =>
      _channel.invokeMethod<void>('openInstallPermission');

  @override
  Future<void> install(File apk) async {
    try {
      await _channel.invokeMethod<void>('install', {'path': apk.path});
    } on PlatformException catch (e) {
      throw UserFacingException(e.message ?? 'Android could not start the install');
    }
  }
}

/// Finds and downloads builds of this app from the fork's GitHub Releases,
/// which the repository's workflow publishes on every push to `main`.
///
/// Every build is signed with the project's development key, and Android only
/// installs an update whose signature matches the installed app, so a file
/// from anywhere else cannot replace the app.
class AppUpdateService {
  AppUpdateService({
    Dio? dio,
    this.apiBase = 'https://api.github.com',
    this.downloadBase = 'https://github.com',
    Future<InstalledBuild> Function()? installedBuild,
    Future<Directory> Function()? cacheDirectory,
  })  : _dio = dio ?? Dio(),
        _installedBuild = installedBuild ?? _packageInfo,
        _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  /// The fork whose releases are this app's builds.
  static const repository = 'sweett00th/astra-retro';

  final Dio _dio;

  /// Overridden only by tests, which serve releases from a local server.
  final String apiBase;
  final String downloadBase;
  final Future<InstalledBuild> Function() _installedBuild;
  final Future<Directory> Function() _cacheDirectory;

  static Future<InstalledBuild> _packageInfo() async {
    final info = await PackageInfo.fromPlatform();
    return InstalledBuild(info.version, int.tryParse(info.buildNumber));
  }

  Future<InstalledBuild> installed() => _installedBuild();

  /// The newest published build, or null when nothing has been published.
  Future<AppRelease?> latest() async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        '$apiBase/repos/$repository/releases/latest',
        options: Options(
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          validateStatus: (status) => status != null,
        ),
      );
    } on DioException catch (e) {
      throw UserFacingException(
          'Could not reach GitHub: ${getUserFriendlyError(e)}');
    }
    final status = response.statusCode!;
    if (status == 404) return null;
    if (status == 403 || status == 429) {
      throw const UserFacingException(
          'GitHub is limiting requests from this network. Try again in a few minutes.');
    }
    if (status != 200 || response.data is! Map) {
      throw UserFacingException('GitHub answered with an error ($status)');
    }
    return _parse(Map<String, dynamic>.from(response.data as Map));
  }

  AppRelease _parse(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    final assets = json['assets'];
    if (tag is! String || tag.isEmpty || assets is! List) {
      throw const UserFacingException('GitHub sent a release this app cannot read');
    }
    final files = <String, (Uri, int)>{};
    for (final asset in assets.whereType<Map>()) {
      final name = asset['name'];
      final url = Uri.tryParse('${asset['browser_download_url'] ?? ''}');
      final size = asset['size'];
      if (name is String && url != null && size is int && _isReleaseFile(url)) {
        files[name] = (url, size);
      }
    }
    final apk = files.entries.where((e) => e.key.endsWith('.apk')).firstOrNull;
    if (apk == null) {
      throw UserFacingException('Release $tag has no APK to install');
    }
    final build = RegExp(r'(\d+)$').firstMatch(tag)?.group(1);
    return AppRelease(
      tag: tag,
      build: build == null ? null : int.tryParse(build),
      notes: (json['body'] as String? ?? '').trim(),
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      apkUrl: apk.value.$1,
      apkSize: apk.value.$2,
      checksumUrl: files['${apk.key}.sha256']?.$1,
    );
  }

  /// Only files of this repository's own releases are ever downloaded.
  bool _isReleaseFile(Uri url) =>
      url.toString().startsWith('$downloadBase/$repository/releases/download/');

  /// Removes a downloaded update. Called once nothing is waiting to be
  /// installed, so an APK is not left in the cache after its build is running.
  Future<void> clearDownloads() async {
    final folder =
        Directory(p.join((await _cacheDirectory()).path, 'app_update'));
    try {
      if (await folder.exists()) await folder.delete(recursive: true);
    } on FileSystemException {
      // Left for the next download, which clears the folder first.
    }
  }

  /// Whether [release] is newer than the running build. A build without a
  /// number on either side cannot be compared and is offered.
  bool isNewer(AppRelease release, InstalledBuild installed) =>
      release.build == null ||
      installed.build == null ||
      release.build! > installed.build!;

  /// Downloads the APK of [release] into the app's cache and checks it
  /// against the published SHA-256 before returning it.
  Future<File> download(
    AppRelease release, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final checksumUrl = release.checksumUrl;
    if (checksumUrl == null) {
      throw UserFacingException(
          'Release ${release.tag} has no checksum file, so its APK cannot be verified');
    }
    final folder =
        Directory(p.join((await _cacheDirectory()).path, 'app_update'));
    // One update at a time: an older download is of no further use.
    if (await folder.exists()) await folder.delete(recursive: true);
    await folder.create(recursive: true);
    final safeTag = release.tag.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final apk = File(p.join(folder.path, 'astra-retro-$safeTag.apk'));

    try {
      final sums = await _dio.get<String>(
        checksumUrl.toString(),
        cancelToken: cancelToken,
        options: Options(
            responseType: ResponseType.plain,
            receiveTimeout: const Duration(seconds: 30)),
      );
      final expected = RegExp(r'^[0-9a-fA-F]{64}(?=\s|$)')
          .firstMatch((sums.data ?? '').trim())
          ?.group(0)
          ?.toLowerCase();
      if (expected == null) {
        throw UserFacingException(
            'The checksum file of ${release.tag} is not a SHA-256 checksum');
      }

      await _dio.download(
        release.apkUrl.toString(),
        apk.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, _) =>
            onProgress?.call(received, release.apkSize),
        options: Options(receiveTimeout: const Duration(seconds: 30)),
      );

      final size = await apk.length();
      if (size != release.apkSize) {
        throw UserFacingException(
            'The download is incomplete: $size of ${release.apkSize} bytes');
      }
      if (await sha256OfFile(apk.path) != expected) {
        throw const UserFacingException(
            'The downloaded file does not match its published checksum. It was not installed.');
      }
      return apk;
    } catch (e) {
      try {
        if (await apk.exists()) await apk.delete();
      } on FileSystemException {
        // Removed with the folder before the next download.
      }
      if (e is UserFacingException) rethrow;
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      throw UserFacingException('The download failed: ${getUserFriendlyError(e)}');
    }
  }
}
