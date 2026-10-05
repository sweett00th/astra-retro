import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/models/romdrop_models.dart';

import 'helpers/romdrop_fakes.dart';

void main() {
  group('RomDrop API examples', () {
    test('capabilities', () {
      final capabilities = RomDropCapabilities.fromJson(
          romDropExample('capabilities.response.json'));
      expect(capabilities.apiVersion, 'v1');
      expect(capabilities.serverVersion, '1.0.0');
      expect(capabilities.deviceName, 'Astra tablet');
      expect(capabilities.canSensitive, isTrue);
      expect(capabilities.isAdmin, isFalse);
      expect(capabilities.libraryAvailable, isTrue);
      expect(capabilities.libraryReason, isNull);
      expect(capabilities.encrypted, isTrue);
    });

    test('platforms carry counts per kind and what is hidden', () {
      final platforms = [
        for (final item in romDropExample(
            'platforms-without-sensitive.response.json')['items'] as List)
          SystemPlatform.fromJson(Map<String, dynamic>.from(item as Map))
      ];
      final nintendo = platforms.first;
      expect(nintendo.id, 'switch');
      expect(nintendo.assetCount, 1);
      expect(nintendo.count(SystemFileKind.firmware), 1);
      expect(nintendo.count(SystemFileKind.keys), 0);
      expect(nintendo.hiddenSensitiveCount, 1);
    });

    test('a platform is matched to the app\'s console by id or alias', () {
      final platforms = [
        for (final item
            in romDropExample('platforms.response.json')['items'] as List)
          SystemPlatform.fromJson(Map<String, dynamic>.from(item as Map))
      ];
      // RomDrop says "ps1" and lists "psx", which is this app's id.
      expect(platforms.firstWhere((p) => p.id == 'ps1').system?.id, 'psx');
      expect(platforms.firstWhere((p) => p.id == 'switch').system?.id, 'switch');
      expect(
          const SystemPlatform(id: 'made-up', name: 'Made up').system, isNull);
    });

    test('asset list with preferred versions', () {
      final page =
          RomDropAssetPage.fromJson(romDropExample('assets.response.json'));
      expect(page.nextCursor, isNull);
      expect(page.items, hasLength(2));
      final firmware = page.items.first;
      expect(firmware.kind, SystemFileKind.firmware);
      expect(firmware.sensitive, isFalse);
      expect(firmware.installMethod, 'emulator_import');
      expect(firmware.preferredVersion!.label, '19.0.1');
      final file = firmware.preferredVersion!.files.single;
      expect(file.filename, 'Firmware 19.0.1.zip');
      expect(file.size, 26);
      expect(file.etag, '"sha256-${file.sha256}"');
      expect(file.available, isTrue);
      expect(file.extract, isFalse, reason: 'an archive is saved as it is');
      expect(file.downloadPath,
          '/api/v1/system/files/fil_b9bb51011b98e6f3/download');
      final keys = page.items.last;
      expect(keys.sensitive, isTrue);
      expect(keys.versionCount, 2);
    });

    test('one asset with all of its versions', () {
      final asset =
          SystemAsset.fromJson(romDropExample('asset.response.json'));
      expect(asset.name, 'prod.keys');
      expect(asset.platformId, 'switch');
      expect(asset.platformName, 'Nintendo Switch');
      expect(asset.versions.map((v) => v.label), ['19.0.1', '18.1.0']);
      expect(asset.versions.first.preferred, isTrue);
      expect(asset.versions.last.preferred, isFalse);
      expect(asset.versions.first.addedOn, '2026-10-05');
      // Same file name in both versions, told apart by id and checksum.
      expect(asset.versions.map((v) => v.files.single.filename).toSet(),
          {'prod.keys'});
      expect(asset.versions.map((v) => v.files.single.id).toSet(), hasLength(2));
    });
  });

  group('refuses what it should not trust', () {
    Map<String, dynamic> asset() => assetJson(
          id: 'ast_1',
          name: 'Synthetic BIOS',
          versions: [
            versionJson(id: 'ver_1', assetId: 'ast_1', preferred: true, files: [
              fileJson(syntheticBytes(16), id: 'fil_1'),
            ]),
          ],
        );

    test('anything that is not a system file', () {
      expect(() => SystemAsset.fromJson(asset()..['content_class'] = 'game'),
          throwsFormatException);
      expect(() => SystemAsset.fromJson(asset()..remove('content_class')),
          throwsFormatException);
    });

    test('an unknown kind', () {
      expect(() => SystemAsset.fromJson(asset()..['kind'] = 'rom'),
          throwsFormatException);
    });

    test('a checksum that is not SHA-256', () {
      final file = fileJson(syntheticBytes(16), id: 'fil_1')..['sha256'] = 'abc';
      expect(() => SystemFileInfo.fromJson(file), throwsFormatException);
    });

    test('a download path that leaves the API', () {
      for (final path in [
        'https://elsewhere.example/file',
        '//elsewhere.example/file',
        '../secret'
      ]) {
        final file = fileJson(syntheticBytes(16), id: 'fil_1')
          ..['download_path'] = path;
        expect(() => SystemFileInfo.fromJson(file), throwsFormatException,
            reason: path);
      }
    });

    test('a file path that could leave the chosen folder', () {
      for (final path in [
        '../synthetic.bin',
        'dir/../synthetic.bin',
        '/synthetic.bin',
        'dir//synthetic.bin',
        'dir\\synthetic.bin',
        './synthetic.bin',
        'synthetic.bin/',
      ]) {
        final file = fileJson(syntheticBytes(16), id: 'fil_1', name: 'synthetic.bin')
          ..['relative_path'] = path;
        expect(() => SystemFileInfo.fromJson(file), throwsFormatException,
            reason: path);
      }
      // The name shown must be the one the path ends in.
      final mismatch =
          fileJson(syntheticBytes(16), id: 'fil_1', name: 'dc/synthetic.bin')
            ..['filename'] = 'other.bin';
      expect(() => SystemFileInfo.fromJson(mismatch), throwsFormatException);
    });

    test('folders inside a version are kept as folders', () {
      final nested = SystemFileInfo.fromJson(
          fileJson(syntheticBytes(16), id: 'fil_1', name: 'dc/sub/synthetic.bin'));
      expect(nested.filename, 'synthetic.bin');
      expect(nested.directories, ['dc', 'sub']);
      expect(systemFile(syntheticBytes(16)).directories, isEmpty);
    });

    test('a response with required fields missing', () {
      expect(() => RomDropCapabilities.fromJson({'api_version': 'v1'}),
          throwsFormatException);
      expect(() => SystemPlatform.fromJson({'id': 'ps1'}),
          throwsFormatException);
    });
  });

  group('what the user is told', () {
    SystemAsset withMethod(String method, [String guidance = '']) =>
        SystemAsset.fromJson(assetJson(
            id: 'ast_1',
            name: 'Synthetic BIOS',
            installMethod: method,
            guidance: guidance,
            versions: const []));

    test('after downloading, per install method', () {
      expect(withMethod('copy_to_folder').afterDownload,
          contains('folder your emulator reads'));
      expect(withMethod('emulator_import').afterDownload,
          contains('import the saved file'));
      expect(withMethod('manual').afterDownload, contains('notes below'));
      expect(withMethod('').afterDownload, contains('Open your emulator'));
    });

    test('the admin\'s own guidance follows the method', () {
      expect(
          withMethod('emulator_import', 'Settings > System > Install keys')
              .afterDownload,
          endsWith('\nSettings > System > Install keys'));
    });

    test('a version without a label is not given an invented one', () {
      const version = SystemAssetVersion(id: 'ver_1', assetId: 'ast_1');
      expect(version.displayLabel, 'Unknown version');
    });

    test('sizes', () {
      expect(formatSystemFileSize(512), '512 B');
      expect(formatSystemFileSize(524288), '512.0 KB');
      expect(formatSystemFileSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatSystemFileSize(3 * 1024 * 1024 * 1024), '3.00 GB');
    });
  });
}
