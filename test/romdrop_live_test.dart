import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_eshop/models/romdrop_models.dart';
import 'package:retro_eshop/services/romdrop/romdrop_api_service.dart';
import 'package:retro_eshop/services/romdrop/system_file_download_manager.dart';
import 'package:retro_eshop/services/romdrop/system_file_storage.dart';

import 'helpers/romdrop_fakes.dart';

/// Runs this app's RomDrop client against a real RomDrop server: pairing,
/// certificate pinning, browsing and resumable downloads.
///
/// Skipped unless told where a server is. Point it at a throwaway test
/// container, never at the library you use: it signs in as the admin, adds
/// two synthetic assets and a device, and removes them again afterwards.
///
///   ROMDROP_LIVE_URL             e.g. https://127.0.0.1:3002
///   ROMDROP_LIVE_ADMIN_PASSWORD  the test server's admin password
///   ROMDROP_LIVE_ADMIN_USER      optional, default "admin"
void main() {
  final url = Platform.environment['ROMDROP_LIVE_URL'];
  final password = Platform.environment['ROMDROP_LIVE_ADMIN_PASSWORD'];
  final user = Platform.environment['ROMDROP_LIVE_ADMIN_USER'] ?? 'admin';
  final skip = url == null || password == null
      ? 'set ROMDROP_LIVE_URL and ROMDROP_LIVE_ADMIN_PASSWORD to run against a test server'
      : false;

  group('against a real RomDrop server', () {
    const folder = SystemFileFolder('tree:live', 'Live test folder');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final bios = syntheticBytes(3 * 1024 * 1024, seed: 11);
    final keys = syntheticBytes(4096, seed: 12);
    const biosName = 'Live Test BIOS (synthetic).bin';

    late String base;
    late String? pin;
    late _Admin admin;
    late Directory temp;
    late FakeSystemFileStorage storage;
    late String biosAsset, keysAsset, keysFile;
    final created = <(String asset, String version)>[];
    late RomDropPairing device;
    late RomDropApiService api;
    late SystemFileInfo biosFile;

    setUpAll(() async {
      base = RomDropApiService.normalizeUrl(url!);
      pin = await RomDropApiService.untrustedFingerprint(base);
      admin = _Admin(base, pin);
      await admin.login(user, password!);
      temp = await Directory.systemTemp.createTemp('rshop_romdrop_live_');

      Future<(String, String)> add(String kind, String name,
          String filename, List<int> bytes, {bool sensitive = false}) async {
        final asset = await admin.json('POST', '/api/v1/admin/system/assets', {
          'platform': 'ps1',
          'kind': kind,
          'name': name,
          'sensitive': sensitive,
          'notes': 'Synthetic bytes written by the R-Shop live test.',
        });
        final version = await admin.json('POST',
            '/api/v1/admin/system/assets/${asset['id']}/versions', {'label': 'live-1'});
        created.add((asset['id'] as String, version['id'] as String));
        final file = await admin.upload(version['id'] as String, filename, bytes);
        await admin.json('POST',
            '/api/v1/admin/system/versions/${version['id']}/commit',
            {'make_preferred': true});
        return (asset['id'] as String, file['id'] as String);
      }

      (biosAsset, _) =
          await add('bios', 'R-Shop live test BIOS $stamp', biosName, bios);
      (keysAsset, keysFile) = await add(
          'keys', 'R-Shop live test keys $stamp', 'live-test.keys', keys,
          sensitive: true);
    });

    tearDownAll(() async {
      // Leave the server as it was found. Deleted versions go to its trash.
      for (final (asset, version) in created) {
        await admin.json('DELETE',
            '/api/v1/admin/system/versions/$version?confirm=$version', null);
        await admin.json('DELETE', '/api/v1/admin/system/assets/$asset', null);
      }
      await temp.delete(recursive: true);
    });

    setUp(() => storage = FakeSystemFileStorage()..folders[folder.uri] = {});

    SystemFileTransfer transfer(SystemFileInfo file, String staging,
            {String? token}) =>
        SystemFileTransfer(
          request: SystemFileRequest(
            file: file,
            assetId: biosAsset,
            assetName: 'live',
            platformId: 'ps1',
            versionLabel: 'live-1',
            folder: folder,
          ),
          uri: Uri.parse('$base${file.downloadPath}'),
          headers: {'Authorization': 'Bearer ${token ?? device.token}'},
          httpClient: () => RomDropApiService.httpClient(pin),
          storage: storage,
          stagingDir: Directory(p.join(temp.path, staging)),
        );

    Matcher failsWith(RomDropErrorKind kind) =>
        throwsA(isA<RomDropException>().having((e) => e.kind, 'kind', kind));

    test('its certificate is the one the admin Status page shows', () async {
      final status = await admin.json('GET', '/api/v1/admin/status', null);
      final tls = status['tls'] as Map;
      if (pin == null) {
        // Publicly trusted certificate or plain HTTP: nothing to pin.
        return;
      }
      expect(RomDropApiService.canonicalFingerprint(pin!),
          RomDropApiService.canonicalFingerprint(tls['fingerprint_sha256'] as String));
      // Without accepting that fingerprint the client talks to nobody.
      await expectLater(
          RomDropApiService(baseUrl: base, token: testToken).capabilities(),
          failsWith(RomDropErrorKind.certificate));
    });

    test('a pairing code becomes a device credential, once', () async {
      final code = await admin.json('POST',
          '/api/v1/admin/devices/pairing-codes',
          {'name': 'R-Shop live test $stamp', 'sensitive': false});

      device = await RomDropApiService.pair(
          baseUrl: base,
          code: code['code'] as String,
          deviceName: 'R-Shop live test $stamp',
          pinnedFingerprint: pin);

      expect(device.token, startsWith('rdt_'));
      expect(device.canSensitive, isFalse);
      await expectLater(
          RomDropApiService.pair(
              baseUrl: base,
              code: code['code'] as String,
              deviceName: 'again',
              pinnedFingerprint: pin),
          failsWith(RomDropErrorKind.unauthorized));

      api = RomDropApiService(
          baseUrl: base, token: device.token, pinnedFingerprint: pin);
      final capabilities = await api.capabilities();
      expect(capabilities.deviceId, device.deviceId);
      expect(capabilities.isAdmin, isFalse);
      expect(capabilities.canSensitive, isFalse);
      expect(capabilities.libraryAvailable, isTrue);
      expect(capabilities.encrypted, base.startsWith('https://'));
    });

    test('browsing shows the asset and hides what is sensitive', () async {
      final platform =
          (await api.platforms()).firstWhere((p) => p.id == 'ps1');
      expect(platform.count(SystemFileKind.bios), greaterThanOrEqualTo(1));
      expect(platform.hiddenSensitiveCount, greaterThanOrEqualTo(1));

      final listed = (await api.assets(platform: 'ps1', kind: SystemFileKind.bios))
          .firstWhere((a) => a.id == biosAsset);
      expect(listed.preferredVersion!.label, 'live-1');

      final asset = await api.asset(biosAsset);
      biosFile = asset.versions.single.files.single;
      expect(biosFile.filename, biosName);
      expect(biosFile.size, bios.length);
      expect(biosFile.sha256, sha256Hex(bios));
      expect(biosFile.etag, '"sha256-${sha256Hex(bios)}"');
      expect(biosFile.available, isTrue);

      expect(
          (await api.assets(platform: 'ps1', kind: SystemFileKind.keys))
              .where((a) => a.id == keysAsset),
          isEmpty);
      await expectLater(api.asset(keysAsset),
          failsWith(RomDropErrorKind.sensitiveNotAllowed));
    });

    test('the download endpoint answers as the client relies on', () async {
      final path = biosFile.downloadPath;
      final auth = {'Authorization': 'Bearer ${device.token}'};

      final head = await admin.raw('HEAD', path, headers: auth);
      expect(head.status, 200);
      expect(head.headers.value('content-length'), '${bios.length}');
      expect(head.headers.value('etag'), biosFile.etag);
      expect(head.headers.value('accept-ranges'), 'bytes');
      expect(head.headers.value('cache-control'), contains('no-store'));
      expect(head.headers.value('content-disposition'), contains('attachment'));
      expect(head.body, isEmpty);

      final part = await admin.raw('GET', path, headers: {
        ...auth,
        'Range': 'bytes=${bios.length - 1000}-',
        'If-Range': biosFile.etag,
      });
      expect(part.status, 206);
      expect(part.headers.value('content-range'),
          'bytes ${bios.length - 1000}-${bios.length - 1}/${bios.length}');
      expect(part.body, bios.sublist(bios.length - 1000));

      final stale = await admin.raw('GET', path, headers: {
        ...auth,
        'Range': 'bytes=10-',
        'If-Range': '"sha256-${'0' * 64}"',
      });
      expect(stale.status, 200, reason: 'a changed file is sent whole');
      expect(stale.body.length, bios.length);

      final beyond = await admin.raw('GET', path,
          headers: {...auth, 'Range': 'bytes=${bios.length}-'});
      expect(beyond.status, 416);
      expect(beyond.headers.value('content-range'), 'bytes */${bios.length}');

      expect((await admin.raw('GET', path)).status, 401);
      expect((await admin.raw('HEAD', path)).status, 401);
      expect((await admin.raw('GET', '$path?token=${device.token}')).status, 401,
          reason: 'a credential in the address is not a credential');
    });

    test('a file downloads, verifies and lands under its own name', () async {
      await transfer(biosFile, 'full').run();

      expect(storage.folders[folder.uri]![biosName], bios);
    });

    test('an interrupted download continues from where it stopped', () async {
      Future<void> seed(String staging, List<int> prefix) async {
        final dir = Directory(p.join(temp.path, staging));
        await dir.create(recursive: true);
        await File(p.join(dir.path, '${biosFile.id}.part')).writeAsBytes(prefix);
        await File(p.join(dir.path, '${biosFile.id}.json')).writeAsString(
            jsonEncode({'etag': biosFile.etag, 'size': biosFile.size}));
      }

      // A wrong first megabyte can only end up in the result if the server
      // sent just the rest and the client appended it: proof of the resume.
      await seed('resume-wrong', syntheticBytes(1024 * 1024, seed: 99));
      await expectLater(
          transfer(biosFile, 'resume-wrong').run(),
          throwsA(isA<SystemFileTransferException>()
              .having((e) => e.message, 'message', contains('checksum'))));
      expect(storage.folders[folder.uri], isEmpty);

      await seed('resume', bios.sublist(0, 1024 * 1024));
      await transfer(biosFile, 'resume').run();
      expect(storage.folders[folder.uri]![biosName], bios);
    });

    test('a sensitive file is refused to a device without that permission',
        () async {
      final file = systemFile(keys, id: keysFile, name: 'live-test.keys');

      await expectLater(transfer(file, 'sensitive').run(),
          failsWith(RomDropErrorKind.sensitiveNotAllowed));
      expect(storage.folders[folder.uri], isEmpty);
    });

    test('a revoked device is turned away', () async {
      await admin.json('POST',
          '/api/v1/admin/devices/${device.deviceId}/revoke', null);

      await expectLater(
          api.capabilities(), failsWith(RomDropErrorKind.unauthorized));
      await expectLater(transfer(biosFile, 'revoked').run(),
          failsWith(RomDropErrorKind.unauthorized));
      expect(storage.folders[folder.uri], isEmpty);
    });
  }, skip: skip);
}

typedef _Answer = ({int status, HttpHeaders headers, List<int> body});

/// The admin side of the server, used only to set the scene and clean up.
class _Admin {
  _Admin(this.base, this.pin);
  final String base;
  final String? pin;
  String? _cookie;
  String? _csrf;

  Future<_Answer> raw(String method, String path,
      {Map<String, String> headers = const {}, List<int>? body}) async {
    final client = RomDropApiService.httpClient(pin);
    try {
      final request = await client.openUrl(method, Uri.parse('$base$path'));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close();
      final bytes = await response
          .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      return (status: response.statusCode, headers: response.headers, body: bytes);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> login(String user, String password) async {
    final answer = await raw('POST', '/api/v1/auth/login',
        headers: {'Content-Type': 'application/json'},
        body: utf8.encode(jsonEncode({'username': user, 'password': password})));
    if (answer.status != 200) {
      fail('Admin sign-in failed (HTTP ${answer.status}).');
    }
    _cookie = answer.headers.value('set-cookie')!.split(';').first;
    _csrf = (jsonDecode(utf8.decode(answer.body)) as Map)['csrf_token'] as String;
  }

  Map<String, String> get _session =>
      {'Cookie': _cookie!, 'X-CSRF-Token': _csrf!};

  Future<Map<String, dynamic>> json(
      String method, String path, Object? body) async {
    final answer = await raw(method, path,
        headers: {
          ..._session,
          if (body != null) 'Content-Type': 'application/json',
        },
        body: body == null ? null : utf8.encode(jsonEncode(body)));
    if (answer.status >= 300) {
      fail('$method $path: HTTP ${answer.status} ${utf8.decode(answer.body)}');
    }
    return answer.body.isEmpty
        ? const {}
        : Map<String, dynamic>.from(jsonDecode(utf8.decode(answer.body)) as Map);
  }

  Future<Map<String, dynamic>> upload(
      String version, String filename, List<int> bytes) async {
    final path = '/api/v1/admin/system/versions/$version/files'
        '?path=${Uri.encodeComponent(filename)}';
    final answer = await raw('PUT', path,
        headers: {..._session, 'Content-Type': 'application/octet-stream'},
        body: bytes);
    if (answer.status != 201) {
      fail('upload $filename: HTTP ${answer.status} ${utf8.decode(answer.body)}');
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(answer.body)) as Map);
  }
}
