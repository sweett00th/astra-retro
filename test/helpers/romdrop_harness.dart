import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/l10n/app_localizations.dart';
import 'package:retro_eshop/models/romdrop_models.dart';
import 'package:retro_eshop/providers/app_providers.dart';
import 'package:retro_eshop/providers/romdrop_providers.dart';
import 'package:retro_eshop/services/romdrop/romdrop_connection.dart';
import 'package:retro_eshop/services/romdrop/romdrop_controller.dart';
import 'package:retro_eshop/services/romdrop/system_file_storage.dart';
import 'package:retro_eshop/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'romdrop_fakes.dart';

const biosFolder =
    SystemFileFolder('tree:bios', 'Internal storage/Emulation/bios');

/// Everything a System Files screen needs, without a server or a device:
/// a fake RomDrop API, fake granted folders and transfers the test steers.
class RomDropHarness {
  RomDropHarness._(
      this.appStorage, this.storage, this.api, this.transfers, this.controller);

  final StorageService appStorage;
  final FakeSystemFileStorage storage;
  final FakeRomDropApi api;
  final FakeTransfers transfers;
  final RomDropController controller;

  static const connection = RomDropConnection(
    baseUrl: 'https://romdrop.test:3002',
    deviceId: 'dev_test',
    deviceName: 'Astra tablet',
  );

  static Future<RomDropHarness> create({bool connected = true}) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final appStorage = StorageService();
    await appStorage.init();
    final storage = FakeSystemFileStorage();
    final api = FakeRomDropApi();
    final transfers = FakeTransfers(storage);
    final controller = RomDropController(
      prefs: await SharedPreferences.getInstance(),
      storage: storage,
      stagingDirectory: () async => Directory('unused-in-screen-tests'),
      apiFactory: (connection, token) => api,
      transferFactory: transfers.create,
      keepAliveWhileBusy: false,
    );
    if (connected) await controller.connect(connection, testToken);
    return RomDropHarness._(appStorage, storage, api, transfers, controller);
  }

  /// Shows [screen] with a navigator above it, as it is inside the app.
  Future<void> pump(WidgetTester tester, Widget screen,
      {bool settle = true}) async {
    // Tall enough that every row is on screen and can be tapped.
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageServiceProvider.overrideWithValue(appStorage),
        systemFileStorageProvider.overrideWithValue(storage),
        romDropControllerProvider.overrideWith((ref) async => controller),
      ],
      child: MaterialApp(
        localizationsDelegates: L.localizationsDelegates,
        supportedLocales: L.supportedLocales,
        home: screen,
      ),
    ));
    if (settle) await tester.pumpAndSettle();
  }

  /// Makes [folder] an existing granted folder and the default destination.
  Future<void> useFolder([SystemFileFolder folder = biosFolder]) async {
    storage.folders.putIfAbsent(folder.uri, () => {});
    await controller.destinations.setDefault(folder);
  }
}

/// A controller button press, then everything it set in motion.
Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------- catalogue

/// A PlayStation BIOS asset with a preferred and an older version, both
/// made of synthetic bytes.
class SyntheticBios {
  SyntheticBios({String state = 'ok'})
      : current = syntheticBytes(2048, seed: 1),
        older = syntheticBytes(1024, seed: 2) {
    json = assetJson(
      id: 'ast_bios000000000001',
      name: 'Synthetic BIOS',
      region: 'US',
      model: 'TEST-5501',
      notes: 'Made-up bytes for tests.',
      installMethod: 'copy_to_folder',
      guidance: 'DuckStation reads BIOS images from its bios folder.',
      versions: [
        // The server lists newest first; the preferred one is the older.
        versionJson(
            id: 'ver_bios000000000002',
            assetId: 'ast_bios000000000001',
            label: 'v4.5',
            deprecated: true,
            notes: 'Kept for comparison.',
            files: [
              fileJson(older,
                  id: 'fil_bios000000000002',
                  versionId: 'ver_bios000000000002',
                  name: 'SYNTH-OLD.BIN'),
            ]),
        versionJson(
            id: 'ver_bios000000000001',
            assetId: 'ast_bios000000000001',
            label: 'v3.0',
            preferred: true,
            pinned: true,
            files: [
              fileJson(current,
                  id: 'fil_bios000000000001',
                  versionId: 'ver_bios000000000001',
                  name: 'Synthetic BIOS v3.0.BIN',
                  state: state),
            ]),
      ],
    );
  }

  final List<int> current;
  final List<int> older;
  late final Map<String, dynamic> json;

  SystemAsset get asset => SystemAsset.fromJson(json);
  SystemAssetVersion get preferred =>
      asset.versions.firstWhere((v) => v.preferred);
  SystemFileInfo get file => preferred.files.single;

  static const platform = SystemPlatform(
    id: 'ps1',
    name: 'PlayStation',
    aliases: ['psx', 'playstation'],
    assetCount: 1,
    kinds: {SystemFileKind.bios: 1},
  );

  /// Puts this asset into the fake server and lets its file be "downloaded".
  void addTo(RomDropHarness harness) {
    harness.api.catalogue.add(asset);
    harness.api.platformsResult = [...harness.api.platformsResult, platform];
    harness.transfers.contents['fil_bios000000000001'] = current;
    harness.transfers.contents['fil_bios000000000002'] = older;
  }
}
