import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_eshop/models/romdrop_models.dart';
import 'package:retro_eshop/services/romdrop/romdrop_connection.dart';
import 'package:retro_eshop/services/romdrop/romdrop_controller.dart';
import 'package:retro_eshop/services/romdrop/system_file_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/romdrop_fakes.dart';

void main() {
  const folder = SystemFileFolder('tree:bios', 'Internal storage/Emulation/bios');
  const connection = RomDropConnection(
    baseUrl: 'https://nas.lan:3002',
    deviceId: 'dev_test',
    deviceName: 'Astra tablet',
    certificateFingerprint: 'AB:CD:EF',
  );
  final content = syntheticBytes(4096);
  final file = systemFile(content);
  final asset = SystemAsset.fromJson(assetJson(
    id: 'ast_test000000000001',
    name: 'Synthetic BIOS',
    versions: [
      versionJson(
          id: 'ver_test000000000001',
          assetId: 'ast_test000000000001',
          preferred: true,
          files: [fileJson(content, id: file.id)]),
    ],
  ));

  late FakeSystemFileStorage storage;
  late SharedPreferences prefs;
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    storage = FakeSystemFileStorage()..folders[folder.uri] = {};
    temp = await Directory.systemTemp.createTemp('rshop_romdrop_controller_');
  });

  tearDown(() => temp.delete(recursive: true));

  RomDropController newController() {
    final controller = RomDropController(
      prefs: prefs,
      storage: storage,
      stagingDirectory: () async => Directory(p.join(temp.path, 'staging')),
      keepAliveWhileBusy: false,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('connection', () {
    test('keeps the device credential in secure storage only', () async {
      final controller = newController();
      expect(controller.configured, isFalse);

      await controller.connect(connection, testToken);

      expect(controller.configured, isTrue);
      expect(controller.api!.baseUrl, 'https://nas.lan:3002');
      expect(controller.api!.pinnedFingerprint, 'AB:CD:EF');
      expect(await const FlutterSecureStorage().read(key: 'romdrop:device_token'),
          testToken);
      for (final key in prefs.getKeys()) {
        expect(prefs.get(key).toString(), isNot(contains('rdt_')),
            reason: 'preference "$key" must not hold the credential');
      }
    });

    test('is back after a restart', () async {
      await newController().connect(connection, testToken);

      final restarted = newController();
      await restarted.load();

      expect(restarted.configured, isTrue);
      expect(restarted.connection!.baseUrl, connection.baseUrl);
      expect(restarted.connection!.deviceName, 'Astra tablet');
      expect(restarted.connection!.certificateFingerprint, 'AB:CD:EF');
      expect(restarted.api!.token, testToken);
    });

    test('is not used when its credential is missing', () async {
      await newController().connect(connection, testToken);
      await const FlutterSecureStorage().delete(key: 'romdrop:device_token');

      final restarted = newController();
      await restarted.load();

      expect(restarted.configured, isFalse);
    });

    test('disconnecting forgets server and credential, not the saved files',
        () async {
      final controller = newController();
      await controller.connect(connection, testToken);
      storage.folders[folder.uri]![file.filename] = content;
      await controller.adoptExisting(asset: asset, file: file, folder: folder);

      await controller.disconnect();

      expect(controller.configured, isFalse);
      expect(controller.connection, isNull);
      expect(await const FlutterSecureStorage().read(key: 'romdrop:device_token'),
          isNull);
      expect(controller.saved[file.id], isNotNull);
      final restarted = newController();
      await restarted.load();
      expect(restarted.configured, isFalse);
      expect(restarted.saved[file.id], isNotNull);
    });

    test('plain HTTP is recognised as unencrypted', () {
      expect(connection.encrypted, isTrue);
      expect(const RomDropConnection(baseUrl: 'http://nas.lan:3002').encrypted,
          isFalse);
    });
  });

  group('destinations', () {
    const vita = SystemFileFolder('tree:vita', 'Internal storage/Vita3K');

    test('a platform uses its own folder, otherwise the default', () async {
      final destinations = newController().destinations;
      expect(destinations.resolve('ps1'), isNull);

      await destinations.setDefault(folder);
      await destinations.setPlatform('vita', vita);

      expect(destinations.resolve('ps1')!.uri, folder.uri);
      expect(destinations.resolve('vita')!.uri, vita.uri);
      expect(destinations.uris, {folder.uri, vita.uri});

      await destinations.setPlatform('vita', null);
      expect(destinations.resolve('vita')!.uri, folder.uri);
      expect(destinations.uris, {folder.uri});
    });

    test('are remembered across restarts', () async {
      final destinations = newController().destinations;
      await destinations.setDefault(folder);
      await destinations.setPlatform('vita', vita);

      final restarted = newController().destinations;

      expect(restarted.defaultFolder!.name, folder.name);
      expect(restarted.platformOverride('vita')!.uri, vita.uri);
    });
  });

  group('what is on the device', () {
    test('a destination is free, the same file, a different file or lost',
        () async {
      final controller = newController();
      expect(await controller.checkDestination(file, folder),
          DestinationState.free);

      storage.folders[folder.uri]![file.filename] = content;
      expect(await controller.checkDestination(file, folder),
          DestinationState.sameFile);

      // Same name and size, other contents.
      storage.folders[folder.uri]![file.filename] =
          syntheticBytes(content.length, seed: 9);
      expect(await controller.checkDestination(file, folder),
          DestinationState.differentFile);

      storage.folders[folder.uri]![file.filename] = syntheticBytes(10);
      expect(await controller.checkDestination(file, folder),
          DestinationState.differentFile);

      storage.revoked.add(folder.uri);
      expect(await controller.checkDestination(file, folder),
          DestinationState.noAccess);
    });

    test('an identical file already in the folder is recorded, not fetched',
        () async {
      final controller = newController();
      storage.folders[folder.uri]![file.filename] = content;

      await controller.adoptExisting(asset: asset, file: file, folder: folder);

      final record = controller.saved[file.id]!;
      expect(record.assetId, asset.id);
      expect(record.platformId, 'ps1');
      expect(record.folderName, folder.name);
      expect(record.sha256, file.sha256);
      expect(await controller.localState(file), LocalFileState.saved);
    });

    test('a file is looked for in the folders it was stored with', () async {
      final controller = newController();
      final nested = systemFile(content,
          id: 'fil_test000000000002', name: 'dc/synthetic-boot.bin');
      // Same name, but directly in the folder: not this file's place.
      storage.folders[folder.uri]!['synthetic-boot.bin'] = content;
      expect(await controller.checkDestination(nested, folder),
          DestinationState.free);

      storage.folders[folder.uri]!['dc/synthetic-boot.bin'] = content;
      expect(await controller.checkDestination(nested, folder),
          DestinationState.sameFile);
      await controller.adoptExisting(asset: asset, file: nested, folder: folder);

      expect(controller.saved[nested.id]!.relativePath, 'dc/synthetic-boot.bin');
      expect(await controller.localState(nested), LocalFileState.saved);
      expect(await newController().localState(nested), LocalFileState.saved,
          reason: 'still found after a restart');
      storage.folders[folder.uri]!.remove('dc/synthetic-boot.bin');
      expect(await controller.localState(nested), LocalFileState.gone);
    });

    test('a saved file that was moved or deleted is reported as gone',
        () async {
      final controller = newController();
      expect(await controller.localState(file), LocalFileState.notSaved);
      storage.folders[folder.uri]![file.filename] = content;
      await controller.adoptExisting(asset: asset, file: file, folder: folder);

      storage.folders[folder.uri]!.remove(file.filename);
      expect(await controller.localState(file), LocalFileState.gone);

      storage.folders[folder.uri]![file.filename] = content;
      expect(await controller.localState(file), LocalFileState.saved);
      storage.revoked.add(folder.uri);
      expect(await controller.localState(file), LocalFileState.gone);
    });

    test('"imported in my emulator" is the user\'s own note and is kept',
        () async {
      final controller = newController();
      storage.folders[folder.uri]![file.filename] = content;
      await controller.adoptExisting(asset: asset, file: file, folder: folder);
      expect(controller.saved[file.id]!.importConfirmed, isFalse,
          reason: 'being in a folder is not being imported');

      await controller.setImportConfirmed(file.id, true);

      expect(controller.saved[file.id]!.importConfirmed, isTrue);
      expect(newController().saved[file.id]!.importConfirmed, isTrue);
    });
  });
}
