import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/system_files/romdrop_connection_screen.dart';
import 'package:retro_eshop/models/romdrop_models.dart';
import 'package:retro_eshop/services/romdrop/romdrop_api_service.dart';
import 'package:retro_eshop/services/romdrop/romdrop_connection.dart';

import '../helpers/romdrop_fakes.dart';
import '../helpers/romdrop_harness.dart';

const _a = LogicalKeyboardKey.gameButtonA;
const _b = LogicalKeyboardKey.gameButtonB;
const _down = LogicalKeyboardKey.arrowDown;

const _url = 'https://192.168.1.10:3002';
final _fingerprint = List.generate(
    32, (i) => (i * 7 + 16).toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
final _otherFingerprint = List.filled(32, 'AB').join(':');

/// What the screen asked of the network, with canned answers.
class _Server {
  _Server(this.harness);
  final RomDropHarness harness;

  /// Fingerprint of a certificate the device does not trust by itself.
  String? presents;
  Object? probeError;
  Object? pairError;
  String issued = 'rdt_ISSUED-BY-TEST-not-a-real-token-00000000';

  final probed = <String>[];
  final paired = <({String baseUrl, String code, String deviceName, String? pin})>[];
  final clients = <({String baseUrl, String token, String? pin})>[];

  Future<String?> probe(String baseUrl) async {
    probed.add(baseUrl);
    if (probeError != null) throw probeError!;
    return presents;
  }

  Future<RomDropPairing> pair({
    required String baseUrl,
    required String code,
    required String deviceName,
    String? pinnedFingerprint,
  }) async {
    paired.add((
      baseUrl: baseUrl,
      code: code,
      deviceName: deviceName,
      pin: pinnedFingerprint
    ));
    if (pairError != null) throw pairError!;
    return RomDropPairing(issued, 'dev_24c2c977dce9a389', deviceName, true);
  }

  RomDropApiService client(String baseUrl, String token, String? pin) {
    clients.add((baseUrl: baseUrl, token: token, pin: pin));
    return harness.api;
  }

  RomDropConnectionScreen get screen =>
      RomDropConnectionScreen(probe: probe, pair: pair, apiBuilder: client);
}

Finder get _fields => find.byType(TextField);

Future<void> _fill(WidgetTester tester,
    {String? url, String? code, String? name}) async {
  if (url != null) await tester.enterText(_fields.at(0), url);
  if (code != null) await tester.enterText(_fields.at(1), code);
  if (name != null) await tester.enterText(_fields.at(2), name);
  await tester.pump();
}

Future<String?> _storedToken() =>
    const FlutterSecureStorage().read(key: 'romdrop:device_token');

void main() {
  group('connecting', () {
    testWidgets('pairs with a code and keeps only the device\'s own credential',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      final server = _Server(h);
      await h.pump(tester, server.screen);

      expect(find.text('SERVER ADDRESS'), findsOneWidget);
      expect(find.text('PAIRING CODE'), findsOneWidget);
      expect(find.text('NAME FOR THIS DEVICE'), findsOneWidget);
      expect(find.text('Test Connection'), findsNothing);

      await _fill(tester, url: '$_url/', code: ' ABCD-EFGH ', name: 'Astra tablet');
      await tapText(tester, 'Connect');

      expect(server.probed, [_url]);
      expect(server.paired.single,
          (baseUrl: _url, code: 'ABCD-EFGH', deviceName: 'Astra tablet', pin: null));
      expect(server.clients.single,
          (baseUrl: _url, token: server.issued, pin: null));
      expect(h.controller.configured, isTrue);
      expect(h.controller.connection!.baseUrl, _url);
      expect(h.controller.connection!.certificateFingerprint, isNull);
      expect(await _storedToken(), server.issued);

      expect(find.text('Connected as "Astra tablet".'), findsOneWidget);
      expect(find.text('Encryption: HTTPS, certificate verified by this device'),
          findsOneWidget);
      expect(find.text('Sensitive files: Allowed for this device'),
          findsOneWidget);
      expect(find.text('Test Connection'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      expect(tester.widget<TextField>(_fields.at(1)).controller!.text, isEmpty,
          reason: 'a used code is not left on screen');
      expect(find.textContaining('rdt_'), findsNothing,
          reason: 'the credential is never displayed');
    });

    testWidgets(
        'a self-signed certificate is shown for comparison before anything is sent',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      final server = _Server(h)..presents = _fingerprint.toLowerCase();
      await h.pump(tester, server.screen);
      await _fill(tester, url: _url, code: 'ABCD-EFGH');

      await tapText(tester, 'Connect');
      expect(find.text('Check RomDrop\'s certificate'), findsOneWidget);
      expect(
          find.textContaining(RomDropApiService.fingerprintBlock(_fingerprint)),
          findsOneWidget);
      expect(find.textContaining('Status page'), findsOneWidget);

      await press(tester, _b); // not the same: go back
      expect(server.paired, isEmpty,
          reason: 'the pairing code stays here until the certificate is accepted');
      expect(h.controller.configured, isFalse);

      await tapText(tester, 'Connect');
      await press(tester, _a); // "They match"

      expect(server.paired.single.pin, _fingerprint.toLowerCase());
      expect(server.clients.single.pin, _fingerprint.toLowerCase());
      expect(h.controller.connection!.certificateFingerprint,
          _fingerprint.toLowerCase());
      expect(find.text('Encryption: HTTPS, certificate you accepted'),
          findsOneWidget);
      expect(
          find.text(
              'Certificate SHA-256: \n${RomDropApiService.fingerprintBlock(_fingerprint)}'),
          findsOneWidget);
    });

    testWidgets('a certificate that changed is not accepted silently',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      await h.controller.connect(
          const RomDropConnection(baseUrl: _url, deviceName: 'Astra tablet')
              .withFingerprint(_fingerprint),
          testToken);
      final server = _Server(h)..presents = _otherFingerprint;
      await h.pump(tester, server.screen);

      expect(tester.widget<TextField>(_fields.at(0)).controller!.text, _url,
          reason: 'the known address is filled in');
      await _fill(tester, code: 'ABCD-EFGH');
      await tapText(tester, 'Pair again');

      expect(find.text('RomDrop\'s certificate changed'), findsOneWidget);
      expect(
          find.textContaining(
              RomDropApiService.fingerprintBlock(_otherFingerprint)),
          findsOneWidget);
      await press(tester, _b);

      expect(server.paired, isEmpty);
      expect(h.controller.connection!.certificateFingerprint, _fingerprint);
      expect(await _storedToken(), testToken);
    });

    testWidgets('the certificate already accepted is not asked about again',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      await h.controller.connect(
          const RomDropConnection(baseUrl: _url, deviceName: 'Astra tablet')
              .withFingerprint(_fingerprint),
          testToken);
      final server = _Server(h)
        ..presents = _fingerprint.replaceAll(':', '').toLowerCase();
      await h.pump(tester, server.screen);
      await _fill(tester, code: 'ABCD-EFGH');

      await tapText(tester, 'Pair again');

      expect(find.textContaining('certificate changed'), findsNothing);
      expect(server.paired.single.pin, _fingerprint);
      expect(await _storedToken(), server.issued);
    });

    testWidgets('an unencrypted address is called out while typing',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      await h.pump(tester, _Server(h).screen);
      expect(find.textContaining('not encrypted'), findsNothing);

      await _fill(tester, url: 'http://192.168.1.10:3002');

      expect(find.textContaining('This address is not encrypted'),
          findsOneWidget);
      expect(find.textContaining('Use the https:// address'), findsOneWidget);
    });

    testWidgets('nothing is contacted for an address or code that cannot work',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      final server = _Server(h);
      await h.pump(tester, server.screen);

      await _fill(tester, url: 'nas.lan:3002', code: 'ABCD-EFGH');
      await tapText(tester, 'Connect');
      expect(find.textContaining('Enter the RomDrop address'), findsOneWidget);

      await _fill(tester, url: 'https://user:pw@nas.lan:3002');
      await tapText(tester, 'Connect');
      expect(find.textContaining('Enter the RomDrop address'), findsOneWidget);

      await _fill(tester, url: _url, code: '   ');
      await tapText(tester, 'Connect');
      expect(find.textContaining('Enter the pairing code'), findsOneWidget);

      expect(server.probed, isEmpty);
      expect(server.paired, isEmpty);
    });

    testWidgets('a wrong or expired code is reported as such', (tester) async {
      final h = await RomDropHarness.create(connected: false);
      final server = _Server(h)
        ..pairError = const RomDropException(RomDropErrorKind.unauthorized,
            'That pairing code is wrong, already used or expired. Create a new one in RomDrop under Devices.');
      await h.pump(tester, server.screen);
      await _fill(tester, url: _url, code: 'ZZZZ-ZZZZ');

      await tapText(tester, 'Connect');

      expect(find.textContaining('already used or expired'), findsOneWidget);
      expect(h.controller.configured, isFalse);
      expect(await _storedToken(), isNull);
      expect(find.text('Connect'), findsOneWidget, reason: 'ready to try again');
    });

    testWidgets('an unreachable server is reported as such', (tester) async {
      final h = await RomDropHarness.create(connected: false);
      final server = _Server(h)
        ..probeError = const RomDropException(RomDropErrorKind.offline,
            'Could not reach RomDrop. Check the address and your network.');
      await h.pump(tester, server.screen);
      await _fill(tester, url: _url, code: 'ABCD-EFGH');

      await tapText(tester, 'Connect');

      expect(find.textContaining('Could not reach RomDrop'), findsOneWidget);
      expect(server.paired, isEmpty);
    });

    testWidgets('a server that is not RomDrop is not saved', (tester) async {
      final h = await RomDropHarness.create(connected: false);
      final server = _Server(h);
      h.api.error = const RomDropException(RomDropErrorKind.invalidResponse,
          'RomDrop sent an answer this app does not understand.');
      await h.pump(tester, server.screen);
      await _fill(tester, url: _url, code: 'ABCD-EFGH');

      await tapText(tester, 'Connect');

      expect(find.textContaining('does not understand'), findsOneWidget);
      expect(h.controller.configured, isFalse);
      expect(await _storedToken(), isNull);
    });

    testWidgets('a pasted device token is masked and used without pairing',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      final server = _Server(h);
      await h.pump(tester, server.screen);
      expect(tester.widget<TextField>(_fields.at(1)).obscureText, isFalse,
          reason: 'a short-lived code is easier to type when visible');

      await _fill(tester, url: _url, code: testToken);
      expect(tester.widget<TextField>(_fields.at(1)).obscureText, isTrue);

      await tapText(tester, 'Connect');

      expect(server.paired, isEmpty);
      expect(server.clients.single.token, testToken);
      expect(await _storedToken(), testToken);
    });
  });

  group('connected', () {
    testWidgets('Test Connection reports what it found', (tester) async {
      final h = await RomDropHarness.create();
      await h.pump(tester, _Server(h).screen);
      expect(find.text('Connected to: https://romdrop.test:3002'),
          findsOneWidget);
      expect(find.text('This device: Astra tablet'), findsOneWidget);

      await tapText(tester, 'Test Connection');
      expect(find.text('Connection works.'), findsOneWidget);

      final example = romDropExample('capabilities.response.json');
      ((example['features'] as Map)['system_library'] as Map)
        ..['available'] = false
        ..['reason'] = '/system is not a mounted folder.';
      ((example['principal'] as Map)['permissions'] as Map)['sensitive'] = false;
      h.api.capabilitiesResult = RomDropCapabilities.fromJson(example);
      await tapText(tester, 'Test Connection');
      expect(
          find.text(
              'Connected, but the system-file library is offline: /system is not a mounted folder.'),
          findsOneWidget);
      expect(
          find.text(
              'Sensitive files: Not allowed (change it in RomDrop > Devices)'),
          findsOneWidget);

      h.api.error = const RomDropException(RomDropErrorKind.unauthorized,
          'RomDrop no longer accepts this device. Pair it again under Settings > RomDrop.');
      await tapText(tester, 'Test Connection');
      expect(find.textContaining('no longer accepts this device'),
          findsOneWidget);
      expect(find.text('Connection works.'), findsNothing);
    });

    testWidgets('Disconnect explains revoking and forgets the credential',
        (tester) async {
      final h = await RomDropHarness.create();
      await h.pump(tester, _Server(h).screen);

      await tapText(tester, 'Disconnect');
      expect(find.text('Disconnect from RomDrop?'), findsOneWidget);
      expect(find.textContaining('Revoke next to "Astra tablet"'),
          findsOneWidget);
      expect(find.textContaining('Files already saved stay'), findsOneWidget);
      await press(tester, _b);
      expect(h.controller.configured, isTrue, reason: 'backed out');

      await tapText(tester, 'Disconnect');
      await press(tester, _a);

      expect(h.controller.configured, isFalse);
      expect(await _storedToken(), isNull);
      expect(
          find.text(
              'Disconnected. Revoke "Astra tablet" in RomDrop under Devices to end its access.'),
          findsOneWidget);
      expect(find.text('Test Connection'), findsNothing);
      expect(find.text('Connect'), findsOneWidget);
    });
  });

  group('controller', () {
    testWidgets('A edits a field, B leaves it, Down reaches the buttons',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      final server = _Server(h);
      await h.pump(tester, server.screen);
      FocusNode text(int index) =>
          tester.widget<TextField>(_fields.at(index)).focusNode!;

      await press(tester, _a);
      expect(text(0).hasFocus, isTrue);
      await press(tester, _b);
      expect(text(0).hasFocus, isFalse);
      expect(find.byType(RomDropConnectionScreen), findsOneWidget,
          reason: 'B left the field, not the screen');

      await press(tester, _down);
      await press(tester, _a);
      expect(text(1).hasFocus, isTrue);
      await press(tester, _b);

      await press(tester, _down); // name
      await press(tester, _down); // Connect
      await press(tester, _a);
      expect(find.textContaining('Enter the RomDrop address'), findsOneWidget,
          reason: 'Connect ran with the empty form');
      expect(server.probed, isEmpty);
    });
  });
}

extension on RomDropConnection {
  RomDropConnection withFingerprint(String fingerprint) => RomDropConnection(
        baseUrl: baseUrl,
        deviceId: deviceId,
        deviceName: deviceName,
        certificateFingerprint: fingerprint,
      );
}
