import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_eshop/models/romdrop_models.dart';
import 'package:retro_eshop/services/romdrop/romdrop_api_service.dart';

import 'helpers/romdrop_fakes.dart';

/// These tests talk to a server on loopback, so they must not initialise the
/// Flutter test binding (it replaces HttpClient with one that answers 400).
void main() {
  late FixtureServer server;

  setUp(() async => server = await FixtureServer.start());
  tearDown(() => server.close());

  RomDropApiService api() =>
      RomDropApiService(baseUrl: server.url, token: testToken);

  Matcher failsWith(RomDropErrorKind kind) =>
      throwsA(isA<RomDropException>().having((e) => e.kind, 'kind', kind));

  group('address', () {
    test('is normalised', () {
      expect(RomDropApiService.normalizeUrl(' https://nas.lan:3002/ '),
          'https://nas.lan:3002');
      expect(RomDropApiService.normalizeUrl('http://192.168.1.10:3002'),
          'http://192.168.1.10:3002');
      expect(RomDropApiService.normalizeUrl('https://nas.lan/romdrop//'),
          'https://nas.lan/romdrop');
    });

    test('rejects what is not a plain http(s) address', () {
      for (final bad in [
        '',
        'nas.lan:3002',
        'ftp://nas.lan',
        'file:///etc/passwd',
        'https://',
        'https://user:secret@nas.lan',
        'https://nas.lan/?token=abc',
        'https://nas.lan/#frag',
      ]) {
        expect(() => RomDropApiService.normalizeUrl(bad), throwsFormatException,
            reason: bad);
      }
    });
  });

  test('fingerprints compare regardless of case and separators', () {
    const colon = 'ab:CD:ef:01';
    expect(RomDropApiService.canonicalFingerprint(colon), 'ABCDEF01');
    expect(RomDropApiService.formatFingerprint('abcdef01'), 'AB:CD:EF:01');
    // Shown in rows of eight bytes, so no byte is split by a line break.
    final block = RomDropApiService.fingerprintBlock(List.filled(32, 'ab').join());
    expect(block.split('\n'), List.filled(4, List.filled(8, 'AB').join(':')));
  });

  group('requests', () {
    test('capabilities sends the device credential as a bearer header only',
        () async {
      server.handler = (request) => respondJson(
          request, 200, romDropExample('capabilities.response.json'));

      final capabilities = await api().capabilities();

      expect(capabilities.deviceName, 'Astra tablet');
      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/v1/capabilities');
      expect(request.headers['authorization'], 'Bearer $testToken');
      expect(request.uri.toString(), isNot(contains(testToken)));
      expect(request.uri.hasQuery, isFalse);
    });

    test('platforms', () async {
      server.handler = (request) =>
          respondJson(request, 200, romDropExample('platforms.response.json'));

      final platforms = await api().platforms();

      expect(platforms.map((p) => p.id), ['switch', 'ps1']);
      expect(server.requests.single.uri.path, '/api/v1/system/platforms');
    });

    test('assets follows every page the server offers', () async {
      final example = romDropExample('assets.response.json');
      final items = example['items'] as List;
      server.handler = (request) {
        final cursor = request.uri.queryParameters['cursor'];
        return respondJson(request, 200, {
          'items': [cursor == null ? items.first : items.last],
          'next_cursor': cursor == null ? 'page-2' : null,
        });
      };

      final assets =
          await api().assets(platform: 'switch', kind: SystemFileKind.keys);

      expect(assets.map((a) => a.name), ['System firmware', 'prod.keys']);
      expect(server.requests, hasLength(2));
      expect(server.requests.first.uri.queryParameters,
          {'platform': 'switch', 'kind': 'keys', 'limit': '100'});
      expect(server.requests.last.uri.queryParameters['cursor'], 'page-2');
    });

    test('assets gives up on a server that never ends its pages', () async {
      server.handler = (request) =>
          respondJson(request, 200, {'items': [], 'next_cursor': 'again'});

      await expectLater(
          api().assets(platform: 'switch', kind: SystemFileKind.keys),
          failsWith(RomDropErrorKind.invalidResponse));
    });

    test('one asset', () async {
      server.handler = (request) =>
          respondJson(request, 200, romDropExample('asset.response.json'));

      final asset = await api().asset('ast_2bb7e3a39ced5137');

      expect(asset.versions, hasLength(2));
      expect(server.requests.single.uri.path,
          '/api/v1/system/assets/ast_2bb7e3a39ced5137');
    });

    test('download address is on the configured server', () {
      final file = systemFile(syntheticBytes(16), id: 'fil_abc');
      expect(api().downloadUri(file).toString(),
          '${server.url}/api/v1/system/files/fil_abc/download');
    });
  });

  group('failures are told apart', () {
    Future<void> answers(int status, [String? code, String message = 'Details.']) async {
      server.handler = (request) => code == null
          ? respondJson(request, status, {'detail': 'not a RomDrop error'})
          : respondJson(request, status, errorBody(code, message));
    }

    test('revoked or unknown device', () async {
      server.handler = (request) => respondJson(
          request, 401, romDropExample('error-unauthorized.response.json'));
      await expectLater(
          api().capabilities(), failsWith(RomDropErrorKind.unauthorized));
    });

    test('sensitive file without permission', () async {
      server.handler = (request) => respondJson(
          request, 403, romDropExample('error-sensitive.response.json'));
      await expectLater(api().asset('ast_1'),
          failsWith(RomDropErrorKind.sensitiveNotAllowed));
    });

    test('sensitive file over plain HTTP', () async {
      await answers(403, 'insecure_transport');
      await expectLater(
          api().asset('ast_1'), failsWith(RomDropErrorKind.insecureTransport));
    });

    test('other refusals', () async {
      await answers(403, 'forbidden', 'Not for devices.');
      await expectLater(
          api().platforms(),
          throwsA(isA<RomDropException>()
              .having((e) => e.kind, 'kind', RomDropErrorKind.forbidden)
              .having((e) => e.message, 'message', 'Not for devices.')));
    });

    test('missing item', () async {
      await answers(404, 'not_found');
      await expectLater(
          api().asset('ast_gone'), failsWith(RomDropErrorKind.notFound));
    });

    test('file changed or missing on the server', () async {
      await answers(409, 'file_changed', 'The stored file changed. Rescan.');
      await expectLater(
          api().asset('ast_1'), failsWith(RomDropErrorKind.fileUnavailable));
    });

    test('library offline', () async {
      await answers(503, 'storage_unavailable', '/system is not mounted.');
      await expectLater(
          api().platforms(),
          throwsA(isA<RomDropException>()
              .having((e) => e.kind, 'kind', RomDropErrorKind.libraryOffline)
              .having((e) => e.message, 'message', '/system is not mounted.')));
    });

    test('too many attempts', () async {
      await answers(429, 'rate_limited');
      await expectLater(
          api().capabilities(), failsWith(RomDropErrorKind.rateLimited));
    });

    test('server error is worth another try', () async {
      await answers(500);
      await expectLater(
          api().capabilities(),
          throwsA(isA<RomDropException>()
              .having((e) => e.kind, 'kind', RomDropErrorKind.server)
              .having((e) => e.retryable, 'retryable', isTrue)));
    });

    test('nothing listening', () async {
      final url = server.url;
      await server.close();
      await expectLater(
          RomDropApiService(baseUrl: url, token: testToken).capabilities(),
          throwsA(isA<RomDropException>()
              .having((e) => e.kind, 'kind', RomDropErrorKind.offline)
              .having((e) => e.retryable, 'retryable', isTrue)));
    });

    test('an answer from something that is not RomDrop', () async {
      server.handler = (request) async {
        request.response
          ..headers.contentType = ContentType.html
          ..write('<html>router login</html>');
        await request.response.close();
      };
      await expectLater(
          api().capabilities(), failsWith(RomDropErrorKind.invalidResponse));
    });

    test('an API version this app does not speak', () async {
      server.handler = (request) => respondJson(
          request,
          200,
          romDropExample('capabilities.response.json')..['api_version'] = 'v2');
      await expectLater(
          api().capabilities(), failsWith(RomDropErrorKind.invalidResponse));
    });
  });

  test('a redirect is refused and the credential goes nowhere else', () async {
    final elsewhere = await FixtureServer.start();
    addTearDown(elsewhere.close);
    elsewhere.handler = (request) => respondJson(
        request, 200, romDropExample('capabilities.response.json'));
    server.handler = (request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set('Location', '${elsewhere.url}/api/v1/capabilities');
      await request.response.close();
    };

    await expectLater(api().capabilities(), throwsA(isA<RomDropException>()));
    expect(elsewhere.requests, isEmpty);
  });

  group('pairing', () {
    test('exchanges the code for this device\'s own credential', () async {
      server.handler = (request) =>
          respondJson(request, 201, romDropExample('pair.response.json'));

      final pairing = await RomDropApiService.pair(
          baseUrl: server.url, code: 'ABCD-EFGH', deviceName: 'Astra tablet');

      expect(pairing.token, startsWith('rdt_'));
      expect(pairing.deviceId, 'dev_24c2c977dce9a389');
      expect(pairing.deviceName, 'Astra tablet');
      expect(pairing.canSensitive, isTrue);
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/v1/devices/pair');
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(request.body),
          {'code': 'ABCD-EFGH', 'device_name': 'Astra tablet'});
    });

    test('a wrong, used or expired code', () async {
      server.handler = (request) => respondJson(
          request, 401, errorBody('invalid_pairing_code', 'Invalid code.'));

      await expectLater(
          RomDropApiService.pair(
              baseUrl: server.url, code: 'ZZZZ-ZZZZ', deviceName: 'Tablet'),
          throwsA(isA<RomDropException>()
              .having((e) => e.kind, 'kind', RomDropErrorKind.unauthorized)
              .having((e) => e.message, 'message', contains('pairing code'))));
    });

    test('an answer without a device credential is not accepted', () async {
      server.handler = (request) => respondJson(request, 201, {
            'token': 'not-a-romdrop-token',
            'device': {'id': 'dev_1', 'name': 'Tablet'}
          });

      await expectLater(
          RomDropApiService.pair(
              baseUrl: server.url, code: 'ABCD-EFGH', deviceName: 'Tablet'),
          failsWith(RomDropErrorKind.invalidResponse));
    });
  });

  group('self-signed certificate', () {
    // RomDrop creates its own certificate with openssl; so does this test.
    // Nothing is committed: the key pair lives in a temporary folder.
    final openssl = _findOpenssl();
    late Directory temp;
    late FixtureServer secure;
    late String expected;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('rshop_tls_');
      final key = p.join(temp.path, 'key.pem');
      final cert = p.join(temp.path, 'cert.pem');
      final made = await Process.run(openssl!, [
        'req', '-x509', '-newkey', 'ec', '-pkeyopt',
        'ec_paramgen_curve:prime256v1', '-nodes', '-keyout', key, '-out', cert,
        '-days', '2', '-subj', '/CN=romdrop-test',
        '-addext', 'subjectAltName=IP:127.0.0.1',
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final printed = await Process.run(
          openssl, ['x509', '-in', cert, '-noout', '-fingerprint', '-sha256']);
      expected = RomDropApiService.formatFingerprint(
          (printed.stdout as String).split('=').last.trim());
      secure = await FixtureServer.start(
          tls: SecurityContext()
            ..useCertificateChain(cert)
            ..usePrivateKey(key));
      secure.handler = (request) => respondJson(
          request, 200, romDropExample('capabilities.response.json'));
    });

    tearDown(() async {
      await secure.close();
      await temp.delete(recursive: true);
    });

    String url() => 'https://127.0.0.1:${secure.port}';

    test('is refused until its fingerprint is accepted', () async {
      await expectLater(
          RomDropApiService(baseUrl: url(), token: testToken).capabilities(),
          failsWith(RomDropErrorKind.certificate));
      expect(secure.requests, isEmpty,
          reason: 'the credential must not be sent to an unverified server');
    });

    test('the fingerprint offered for comparison is the certificate\'s',
        () async {
      expect(await RomDropApiService.untrustedFingerprint(url()), expected);
      expect(secure.requests, isEmpty, reason: 'looking sends nothing');
    });

    test('is accepted with exactly the pinned fingerprint', () async {
      final capabilities = await RomDropApiService(
              baseUrl: url(),
              token: testToken,
              // As a user would copy it: lower case, no separators.
              pinnedFingerprint: expected.replaceAll(':', '').toLowerCase())
          .capabilities();
      expect(capabilities.deviceName, 'Astra tablet');
      expect(secure.requests.single.headers['authorization'],
          'Bearer $testToken');
    });

    test('is refused when the pin belongs to another certificate', () async {
      final other = List.filled(32, 'AB').join(':');
      await expectLater(
          RomDropApiService(
                  baseUrl: url(), token: testToken, pinnedFingerprint: other)
              .capabilities(),
          failsWith(RomDropErrorKind.certificate));
      expect(secure.requests, isEmpty);
    });

    test('an empty pin accepts nothing', () async {
      await expectLater(
          RomDropApiService(
                  baseUrl: url(), token: testToken, pinnedFingerprint: '')
              .capabilities(),
          failsWith(RomDropErrorKind.certificate));
    });

    test('pairing is held to the pin as well', () async {
      secure.handler = (request) =>
          respondJson(request, 201, romDropExample('pair.response.json'));
      await expectLater(
          RomDropApiService.pair(
              baseUrl: url(), code: 'ABCD-EFGH', deviceName: 'Tablet'),
          failsWith(RomDropErrorKind.certificate));
      expect(secure.requests, isEmpty);

      final pairing = await RomDropApiService.pair(
          baseUrl: url(),
          code: 'ABCD-EFGH',
          deviceName: 'Tablet',
          pinnedFingerprint: expected);
      expect(pairing.token, startsWith('rdt_'));
    });

    test('plain HTTP has no certificate to compare', () async {
      expect(await RomDropApiService.untrustedFingerprint(server.url), isNull);
    });
  }, skip: _findOpenssl() == null ? 'openssl is not installed' : false);
}

/// openssl from PATH, or the copy that ships with Git for Windows.
String? _findOpenssl() {
  final candidates = [
    'openssl',
    r'C:\Program Files\Git\mingw64\bin\openssl.exe',
    r'C:\Program Files\Git\usr\bin\openssl.exe',
  ];
  for (final candidate in candidates) {
    try {
      if (Process.runSync(candidate, ['version']).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      // Not here; try the next place.
    }
  }
  return null;
}
