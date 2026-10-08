// Real loopback HTTP: this file must not initialise the Flutter test binding,
// which replaces HttpClient with one that answers 400.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_eshop/services/app_update_service.dart';
import 'package:retro_eshop/utils/friendly_error.dart';

import 'folder_packer_test.dart' show syntheticBytes;
import 'helpers/romdrop_fakes.dart' show FixtureServer, respondJson;

const _repo = AppUpdateService.repository;

void main() {
  // Stands in for a build; nothing here is a real APK.
  final apkBytes = syntheticBytes(180000, seed: 7);
  final apkSha = sha256.convert(apkBytes).toString();

  late Directory tmp;
  late FixtureServer server;
  late AppUpdateService service;

  /// What the fixture answers; each test adjusts it.
  late int status;
  late String tag;
  late int advertisedSize;
  late String? checksumText;
  late String Function(String name) assetUrl;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('app_update_service_test_');
    server = await FixtureServer.start();
    status = 200;
    tag = 'm1-build-16';
    advertisedSize = apkBytes.length;
    checksumText = '$apkSha  astra-retro-debug.apk\n';
    assetUrl = (name) => '${server.url}/$_repo/releases/download/$tag/$name';

    server.handler = (request) async {
      final path = request.uri.path;
      if (path == '/repos/$_repo/releases/latest') {
        if (status != 200) {
          return respondJson(request, status, {'message': 'Not available'});
        }
        return respondJson(request, 200, {
          'tag_name': tag,
          'name': 'Development build 16',
          'body': 'Changes in this build:\n- Save folder games as one .zip\n',
          'published_at': '2026-10-08T18:00:00Z',
          'assets': [
            {
              'name': 'astra-retro-debug.apk',
              'size': advertisedSize,
              'browser_download_url': assetUrl('astra-retro-debug.apk'),
            },
            if (checksumText != null)
              {
                'name': 'astra-retro-debug.apk.sha256',
                'size': checksumText!.length,
                'browser_download_url': assetUrl('astra-retro-debug.apk.sha256'),
              },
          ],
        });
      }
      if (path.endsWith('/astra-retro-debug.apk.sha256') && checksumText != null) {
        request.response
          ..statusCode = 200
          ..write(checksumText);
        return request.response.close();
      }
      if (path.endsWith('/astra-retro-debug.apk')) {
        request.response
          ..statusCode = 200
          ..contentLength = apkBytes.length
          ..add(apkBytes);
        return request.response.close();
      }
      return respondJson(request, 404, {'message': 'Not Found'});
    };

    service = AppUpdateService(
      apiBase: server.url,
      downloadBase: server.url,
      installedBuild: () async => const InstalledBuild('1.7.0', 15),
      cacheDirectory: () async => tmp,
    );
  });

  tearDown(() async {
    await server.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a just-closed file for a moment; the OS clears temp.
    }
  });

  List<String> requested() => [for (final r in server.requests) r.uri.path];

  group('finding the newest build', () {
    test('reads the release the workflow published', () async {
      final release = (await service.latest())!;

      expect(release.tag, 'm1-build-16');
      expect(release.build, 16);
      expect(release.label, 'build 16');
      expect(release.notes, startsWith('Changes in this build:'));
      expect(release.publishedAt, DateTime.utc(2026, 10, 8, 18));
      expect(release.apkSize, apkBytes.length);
      expect(release.apkUrl.path, endsWith('/m1-build-16/astra-retro-debug.apk'));
      expect(release.checksumUrl!.path, endsWith('.apk.sha256'));
      expect(server.requests.single.headers['accept'],
          'application/vnd.github+json');
    });

    test('a build is newer only when its number is higher', () async {
      final release = (await service.latest())!;
      expect(service.isNewer(release, const InstalledBuild('1.7.0', 15)), isTrue);
      expect(service.isNewer(release, const InstalledBuild('1.7.0', 16)), isFalse);
      expect(service.isNewer(release, const InstalledBuild('1.7.0', 17)), isFalse);
      // Without a number on one side there is nothing to compare: offer it.
      expect(service.isNewer(release, const InstalledBuild('1.7.0', null)), isTrue);
      tag = 'nightly';
      final unnumbered = (await service.latest())!;
      expect(unnumbered.build, isNull);
      expect(unnumbered.label, 'nightly');
      expect(service.isNewer(unnumbered, const InstalledBuild('1.7.0', 99)), isTrue);
    });

    test('nothing published yet is not an error', () async {
      status = 404;
      expect(await service.latest(), isNull);
    });

    test('GitHub rate limiting is explained', () async {
      status = 403;
      await expectLater(
          service.latest(),
          throwsA(isA<UserFacingException>().having(
              (e) => e.message, 'message', contains('limiting requests'))));
    });

    test('a server that cannot be reached is explained', () async {
      await server.close();
      await expectLater(
          service.latest(),
          throwsA(isA<UserFacingException>().having(
              (e) => e.message, 'message', startsWith('Could not reach GitHub'))));
    });

    test('files outside this repository\'s releases are never used', () async {
      assetUrl = (name) => '${server.url}/someone-else/app/releases/download/$tag/$name';
      await expectLater(
          service.latest(),
          throwsA(isA<UserFacingException>()
              .having((e) => e.message, 'message', contains('no APK'))));
    });
  });

  group('downloading a build', () {
    test('saves the APK into the app cache after checking it', () async {
      final release = (await service.latest())!;
      final progress = <(int, int)>[];

      final apk = await service.download(release,
          onProgress: (received, total) => progress.add((received, total)));

      expect(apk.path,
          p.join(tmp.path, 'app_update', 'astra-retro-m1-build-16.apk'));
      expect(apk.readAsBytesSync(), apkBytes);
      expect(progress.last, (apkBytes.length, apkBytes.length));
      expect(requested().last, endsWith('/astra-retro-debug.apk'));
    });

    test('a file that does not match its checksum is thrown away', () async {
      checksumText = '${'0' * 64}  astra-retro-debug.apk\n';
      final release = (await service.latest())!;

      await expectLater(
          service.download(release),
          throwsA(isA<UserFacingException>().having((e) => e.message, 'message',
              contains('does not match its published checksum'))));
      expect(Directory(p.join(tmp.path, 'app_update')).listSync(), isEmpty);
    });

    test('a short download is thrown away', () async {
      advertisedSize = apkBytes.length + 1;
      final release = (await service.latest())!;

      await expectLater(
          service.download(release),
          throwsA(isA<UserFacingException>()
              .having((e) => e.message, 'message', contains('incomplete'))));
      expect(Directory(p.join(tmp.path, 'app_update')).listSync(), isEmpty);
    });

    test('a release without a checksum is not downloaded at all', () async {
      checksumText = null;
      final release = (await service.latest())!;
      expect(release.checksumUrl, isNull);

      await expectLater(
          service.download(release),
          throwsA(isA<UserFacingException>().having(
              (e) => e.message, 'message', contains('cannot be verified'))));
      expect(requested().where((path) => path.endsWith('.apk')), isEmpty);
    });

    test('something that is not a checksum is refused', () async {
      checksumText = '<html>Not Found</html>';
      final release = (await service.latest())!;

      await expectLater(
          service.download(release),
          throwsA(isA<UserFacingException>().having((e) => e.message, 'message',
              contains('is not a SHA-256 checksum'))));
      expect(requested().where((path) => path.endsWith('.apk')), isEmpty);
    });

    test('an earlier download is cleared first', () async {
      final stale = File(p.join(tmp.path, 'app_update', 'astra-retro-m1-build-9.apk'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);

      await service.download((await service.latest())!);

      expect(stale.existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, 'app_update')).listSync(), hasLength(1));
    });

    test('a cancelled download leaves nothing behind', () async {
      final release = (await service.latest())!;
      final cancel = CancelToken()..cancel();

      await expectLater(
          service.download(release, cancelToken: cancel),
          throwsA(isA<DioException>()
              .having((e) => CancelToken.isCancel(e), 'cancelled', isTrue)));
      expect(Directory(p.join(tmp.path, 'app_update')).listSync(), isEmpty);
    });
  });
}
