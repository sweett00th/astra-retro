import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/system_files/romdrop_connection_screen.dart';
import 'package:retro_eshop/features/system_files/system_asset_screen.dart';
import 'package:retro_eshop/features/system_files/system_assets_screen.dart';
import 'package:retro_eshop/features/system_files/system_destinations_screen.dart';
import 'package:retro_eshop/features/system_files/system_files_screen.dart';
import 'package:retro_eshop/features/system_files/system_transfers_screen.dart';
import 'package:retro_eshop/models/romdrop_models.dart';
import 'package:retro_eshop/services/romdrop/romdrop_api_service.dart';
import 'package:retro_eshop/services/romdrop/system_file_download_manager.dart';
import 'package:retro_eshop/services/romdrop/system_file_storage.dart';

import '../helpers/romdrop_fakes.dart';
import '../helpers/romdrop_harness.dart';

const _a = LogicalKeyboardKey.gameButtonA;
const _b = LogicalKeyboardKey.gameButtonB;
const _x = LogicalKeyboardKey.gameButtonX;
const _down = LogicalKeyboardKey.arrowDown;
const _up = LogicalKeyboardKey.arrowUp;

void main() {
  group('System Files', () {
    testWidgets('not connected: says so and leads to the connection screen',
        (tester) async {
      final h = await RomDropHarness.create(connected: false);
      await h.pump(tester, const SystemFilesScreen());

      expect(find.text('Not connected to RomDrop'), findsOneWidget);
      expect(find.text('Connect to RomDrop'), findsOneWidget);
      expect(h.api.capabilitiesCalls, 0);

      await press(tester, _a);
      expect(find.byType(RomDropConnectionScreen), findsOneWidget);
    });

    testWidgets('loading, then the platforms that have files', (tester) async {
      final h = await RomDropHarness.create();
      SyntheticBios().addTo(h);
      h.api.platformsResult = [
        ...h.api.platformsResult,
        const SystemPlatform(id: 'vita', name: 'PlayStation Vita'), // empty
      ];
      h.api.hold = Completer<void>();
      await h.pump(tester, const SystemFilesScreen(), settle: false);
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('PlayStation'), findsNothing);

      h.api.hold!.complete();
      h.api.hold = null;
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('PlayStation'), findsOneWidget);
      expect(find.text('BIOS 1'), findsOneWidget);
      expect(find.text('1 file'), findsOneWidget);
      expect(find.text('PlayStation Vita'), findsNothing);
      expect(find.text('https://romdrop.test:3002 as "Astra tablet"'),
          findsOneWidget);
    });

    testWidgets('offline: says so, and Try again loads once it is back',
        (tester) async {
      final h = await RomDropHarness.create();
      SyntheticBios().addTo(h);
      h.api.error = const RomDropException(RomDropErrorKind.offline,
          'Could not reach RomDrop. Check that the server is on and you are on the same network.');
      await h.pump(tester, const SystemFilesScreen());

      expect(find.text('RomDrop is not reachable'), findsOneWidget);
      expect(find.textContaining('Could not reach RomDrop'), findsOneWidget);
      expect(find.text('PlayStation'), findsNothing);

      h.api.error = null;
      await tapText(tester, 'Try again');

      expect(find.text('RomDrop is not reachable'), findsNothing);
      expect(find.text('PlayStation'), findsOneWidget);
    });

    testWidgets('a device RomDrop no longer accepts', (tester) async {
      final h = await RomDropHarness.create();
      h.api.error = const RomDropException(RomDropErrorKind.unauthorized,
          'RomDrop no longer accepts this device. Pair it again under Settings > RomDrop.');
      await h.pump(tester, const SystemFilesScreen());

      expect(find.text('RomDrop no longer accepts this device'), findsOneWidget);
      expect(find.textContaining('Pair it again'), findsOneWidget);
      expect(find.text('RomDrop connection'), findsOneWidget);
    });

    testWidgets('a certificate that was not accepted', (tester) async {
      final h = await RomDropHarness.create();
      h.api.error = const RomDropException(
          RomDropErrorKind.certificate, 'RomDrop presented a certificate…');
      await h.pump(tester, const SystemFilesScreen());

      expect(
          find.text('RomDrop\'s certificate is not accepted'), findsOneWidget);
    });

    testWidgets('library offline on the server', (tester) async {
      final h = await RomDropHarness.create();
      final example = romDropExample('capabilities.response.json');
      ((example['features'] as Map)['system_library'] as Map)
        ..['available'] = false
        ..['reason'] = '/system is not a mounted folder.';
      h.api.capabilitiesResult = RomDropCapabilities.fromJson(example);
      await h.pump(tester, const SystemFilesScreen());

      expect(find.text('The system-file library is offline'), findsOneWidget);
      expect(find.text('/system is not a mounted folder.'), findsOneWidget);
      expect(h.api.platformCalls, 0);
    });

    testWidgets('empty library', (tester) async {
      final h = await RomDropHarness.create();
      await h.pump(tester, const SystemFilesScreen());

      expect(find.text('No system files yet'), findsOneWidget);
    });

    testWidgets('sensitive files this device may not see are counted',
        (tester) async {
      final h = await RomDropHarness.create();
      h.api.platformsResult = [
        for (final item in romDropExample(
            'platforms-without-sensitive.response.json')['items'] as List)
          SystemPlatform.fromJson(Map<String, dynamic>.from(item as Map))
      ];
      await h.pump(tester, const SystemFilesScreen());

      expect(find.text('1 sensitive file is hidden'), findsOneWidget);
      expect(find.textContaining('Allow it in RomDrop under Devices'),
          findsOneWidget);
    });

    testWidgets('X refreshes', (tester) async {
      final h = await RomDropHarness.create();
      await h.pump(tester, const SystemFilesScreen());
      final before = h.api.capabilitiesCalls;

      await press(tester, _x);

      expect(h.api.capabilitiesCalls, before + 1);
    });

    testWidgets('Up and Down move between rows', (tester) async {
      final h = await RomDropHarness.create();
      SyntheticBios().addTo(h);
      await h.pump(tester, const SystemFilesScreen());
      // Rows: PlayStation, Destinations, RomDrop connection.

      await press(tester, _up); // already at the top
      await press(tester, _down);
      await press(tester, _a);
      expect(find.byType(SystemDestinationsScreen), findsOneWidget);

      await press(tester, _b);
      await press(tester, _down);
      await press(tester, _down); // already at the bottom
      await press(tester, _a);
      expect(find.byType(RomDropConnectionScreen), findsOneWidget);
    });

    testWidgets(
        'controller: platform > kind > asset > version, and Back all the way',
        (tester) async {
      final h = await RomDropHarness.create();
      SyntheticBios().addTo(h);
      await h.pump(tester, const SystemFilesScreen());

      await press(tester, _a);
      expect(find.byType(SystemKindsScreen), findsOneWidget);
      expect(find.text('BIOS'), findsOneWidget);
      expect(find.text('Firmware'), findsNothing, reason: 'nothing of that kind');

      await press(tester, _a);
      expect(find.byType(SystemAssetsScreen), findsOneWidget);
      expect(find.text('PlayStation · BIOS'), findsOneWidget);
      expect(find.text('Synthetic BIOS'), findsOneWidget);
      expect(
          find.text('v3.0 · Synthetic BIOS v3.0.BIN · 2.0 KB · US · TEST-5501'),
          findsOneWidget);
      expect(find.text('2 versions'), findsOneWidget);

      await press(tester, _a);
      expect(find.byType(SystemAssetScreen), findsOneWidget);
      expect(find.text('v3.0'), findsOneWidget);
      expect(find.text('v4.5'), findsOneWidget);

      await press(tester, _a);
      expect(find.byType(SystemVersionScreen), findsOneWidget);
      expect(find.text('Synthetic BIOS · v3.0'), findsOneWidget,
          reason: 'the preferred version is the first row');

      await press(tester, _b);
      expect(find.byType(SystemVersionScreen), findsNothing);
      await press(tester, _b);
      expect(find.byType(SystemAssetScreen), findsNothing);
      await press(tester, _b);
      expect(find.byType(SystemAssetsScreen), findsNothing);
      await press(tester, _b);
      expect(find.byType(SystemKindsScreen), findsNothing);
      expect(find.text('System Files'), findsOneWidget);
    });
  });

  group('Assets of a kind', () {
    testWidgets('mark what is sensitive and what is already on the device',
        (tester) async {
      final h = await RomDropHarness.create();
      final keys = syntheticBytes(64, seed: 4);
      h.api.catalogue.add(SystemAsset.fromJson(assetJson(
        id: 'ast_keys000000000001',
        platformId: 'switch',
        platformName: 'Nintendo Switch',
        aliases: const ['nx'],
        kind: 'keys',
        name: 'Synthetic keys',
        sensitive: true,
        versions: [
          versionJson(
              id: 'ver_keys000000000001',
              assetId: 'ast_keys000000000001',
              preferred: true,
              files: [fileJson(keys, id: 'fil_keys000000000001', name: 'synthetic.keys')]),
        ],
      )));
      await h.useFolder();
      h.storage.folders[biosFolder.uri]!['synthetic.keys'] = keys;
      final asset = h.api.catalogue.single;
      await h.controller.adoptExisting(
          asset: asset,
          file: asset.preferredVersion!.files.single,
          folder: biosFolder);

      await h.pump(
          tester,
          const SystemAssetsScreen(
              platform: SystemPlatform(id: 'switch', name: 'Nintendo Switch'),
              kind: SystemFileKind.keys));

      expect(find.text('Synthetic keys'), findsOneWidget);
      expect(find.text('SENSITIVE'), findsOneWidget);
      expect(find.text('ON THIS DEVICE'), findsOneWidget);
      // A version nobody labelled is not given a made-up number.
      expect(find.textContaining('Unknown version'), findsOneWidget);
    });

    testWidgets('empty and failed lists say which', (tester) async {
      final h = await RomDropHarness.create();
      await h.pump(
          tester,
          const SystemAssetsScreen(
              platform: SyntheticBios.platform, kind: SystemFileKind.bios));
      expect(find.text('No BIOS files for PlayStation'), findsOneWidget);

      h.api.error = const RomDropException(RomDropErrorKind.offline,
          'Could not reach RomDrop. Check that the server is on and you are on the same network.');
      await press(tester, _x);
      expect(find.text('Could not load BIOS'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('An asset', () {
    testWidgets('lists the preferred version first, with what each one is',
        (tester) async {
      final h = await RomDropHarness.create();
      final bios = SyntheticBios()..addTo(h);
      await h.pump(tester, SystemAssetScreen(assetId: bios.asset.id));

      final preferred = tester.getTopLeft(find.text('v3.0')).dy;
      final other = tester.getTopLeft(find.text('v4.5')).dy;
      expect(preferred, lessThan(other),
          reason: 'the server listed v4.5 first; preferred goes on top');
      expect(find.text('PREFERRED'), findsOneWidget);
      expect(find.text('PINNED'), findsOneWidget);
      expect(find.text('DEPRECATED'), findsOneWidget);
      expect(find.text('Synthetic BIOS v3.0.BIN · 2.0 KB · added 2026-10-05'),
          findsOneWidget);
      expect(find.text('US'), findsOneWidget);
      expect(find.text('TEST-5501'), findsOneWidget);
      expect(find.text('Made-up bytes for tests.'), findsOneWidget);
      expect(find.textContaining('DuckStation reads BIOS images'),
          findsOneWidget);
    });

    testWidgets('that is gone says so', (tester) async {
      final h = await RomDropHarness.create();
      await h.pump(tester, const SystemAssetScreen(assetId: 'ast_gone'));

      expect(find.text('Could not load this file'), findsOneWidget);
      expect(find.textContaining('no longer has this item'), findsOneWidget);
    });
  });

  group('A version', () {
    late RomDropHarness h;
    late SyntheticBios bios;
    const name = 'Synthetic BIOS v3.0.BIN';

    Future<void> open(WidgetTester tester, {String state = 'ok'}) async {
      bios = SyntheticBios(state: state)..addTo(h);
      await h.pump(tester,
          SystemVersionScreen(asset: bios.asset, version: bios.preferred));
    }

    testWidgets('offers a download and nothing that sounds like a game',
        (tester) async {
      h = await RomDropHarness.create();
      await open(tester);

      expect(find.text(name), findsOneWidget);
      expect(find.textContaining('Not on this device'), findsOneWidget);
      expect(find.textContaining('SHA-256 ${bios.file.sha256}'), findsOneWidget);
      expect(find.text('PREFERRED'), findsOneWidget);
      expect(find.text('PINNED'), findsOneWidget);
      for (final word in ['Launch', 'Play', 'Installed', 'Run']) {
        expect(
            find.textContaining(RegExp('\\b$word\\b', caseSensitive: false)),
            findsNothing,
            reason: 'a system file is saved, never "$word"');
      }
      expect(find.textContaining('Imported in my emulator'), findsNothing,
          reason: 'nothing to tick off before the file is on the device');
    });

    testWidgets(
        'first download asks for a folder, shows progress, then "saved"',
        (tester) async {
      h = await RomDropHarness.create();
      await open(tester);
      h.storage.nextPick = biosFolder;

      await tapText(tester, name);
      expect(find.text('Where should system files go?'), findsOneWidget);
      expect(find.textContaining('Android/data'), findsOneWidget);
      await press(tester, _a);

      expect(find.textContaining('Downloading from RomDrop 50%'), findsOneWidget);
      expect(find.textContaining('Select to cancel'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Saves to ${biosFolder.name}'), findsOneWidget);
      expect(h.transfers.started.single.folder.uri, biosFolder.uri);
      expect(h.transfers.started.single.replace, isFalse);

      h.transfers.finish(bios.file.id);
      await tester.pumpAndSettle();

      expect(find.textContaining('Saved to ${biosFolder.name}'), findsOneWidget);
      expect(find.text('ON THIS DEVICE'), findsOneWidget);
      expect(h.storage.folders[biosFolder.uri]![name], bios.current,
          reason: 'saved under its original name');
      // On the device is not the same as in the emulator.
      expect(find.text('Imported in my emulator: not yet'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\bInstalled\b')), findsNothing);

      await tapText(tester, 'Imported in my emulator: not yet');
      expect(find.text('Imported in my emulator: yes'), findsOneWidget);
      expect(h.controller.saved[bios.file.id]!.importConfirmed, isTrue);
    });

    testWidgets('backing out of the folder picker starts nothing',
        (tester) async {
      h = await RomDropHarness.create();
      await open(tester);
      h.storage.nextPick = null;

      await tapText(tester, name);
      await press(tester, _a); // "Choose folder", then the picker is dismissed

      expect(h.storage.pickInitialUris, hasLength(1));
      expect(h.transfers.started, isEmpty);
      expect(find.textContaining('Not on this device'), findsOneWidget);
      expect(find.text('Choose where to save'), findsOneWidget);
    });

    testWidgets('a running download can be cancelled', (tester) async {
      h = await RomDropHarness.create();
      await h.useFolder();
      await open(tester);

      await tapText(tester, name);
      expect(find.textContaining('Select to cancel'), findsOneWidget);
      await tapText(tester, name);

      expect(find.textContaining('Not on this device'), findsOneWidget);
      expect(h.storage.folders[biosFolder.uri], isEmpty);
      expect(h.controller.saved[bios.file.id], isNull);
    });

    testWidgets('a failed download says why and continues when selected',
        (tester) async {
      h = await RomDropHarness.create();
      await h.useFolder();
      await open(tester);

      await tapText(tester, name);
      h.transfers.fail(
          bios.file.id,
          const RomDropException(RomDropErrorKind.unauthorized,
              'RomDrop no longer accepts this device. Pair it again under Settings > RomDrop.'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Pair it again'), findsOneWidget);
      expect(find.textContaining('Select to continue the download'),
          findsOneWidget);
      expect(h.storage.folders[biosFolder.uri], isEmpty);

      await tapText(tester, name);
      expect(h.transfers.started, hasLength(2));
      h.transfers.finish(bios.file.id);
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved to ${biosFolder.name}'), findsOneWidget);
    });

    testWidgets('a different file of that name is only replaced on request',
        (tester) async {
      h = await RomDropHarness.create();
      await h.useFolder();
      final mine = syntheticBytes(300, seed: 8);
      h.storage.folders[biosFolder.uri]![name] = mine;
      await open(tester);

      await tapText(tester, name);
      expect(find.text('Replace $name?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await press(tester, _b);

      expect(h.transfers.started, isEmpty);
      expect(h.storage.folders[biosFolder.uri]![name], mine);

      await tapText(tester, name);
      await press(tester, _a);
      expect(h.transfers.started.single.replace, isTrue);
      h.transfers.finish(bios.file.id);
      await tester.pumpAndSettle();
      expect(h.storage.folders[biosFolder.uri]![name], bios.current);
    });

    testWidgets('an identical file already there is kept, not downloaded',
        (tester) async {
      h = await RomDropHarness.create();
      await h.useFolder();
      h.storage.folders[biosFolder.uri]![name] = SyntheticBios().current;
      await open(tester);

      await tapText(tester, name);

      expect(h.transfers.started, isEmpty);
      expect(find.textContaining('already in ${biosFolder.name}'),
          findsOneWidget);
      expect(find.textContaining('Saved to ${biosFolder.name}'), findsOneWidget);
      expect(find.text('ON THIS DEVICE'), findsOneWidget);
    });

    testWidgets('lost folder access is explained before anything downloads',
        (tester) async {
      h = await RomDropHarness.create();
      await h.useFolder();
      h.storage.revoked.add(biosFolder.uri);
      await open(tester);

      await tapText(tester, name);
      expect(find.text('Folder access was lost'), findsOneWidget);
      expect(find.textContaining('Nothing was downloaded'), findsOneWidget);
      await press(tester, _b);
      expect(h.transfers.started, isEmpty);

      const other = SystemFileFolder('tree:other', 'Internal storage/BIOS');
      h.storage.nextPick = other;
      await tapText(tester, name);
      await press(tester, _a); // "Choose folder again"

      expect(h.storage.pickInitialUris.single, biosFolder.uri);
      expect(h.transfers.started.single.folder.uri, other.uri);
      expect(find.text('Saves to ${other.name}'), findsOneWidget);
    });

    testWidgets('a file the server cannot vouch for is not offered',
        (tester) async {
      h = await RomDropHarness.create();
      await h.useFolder();
      await open(tester, state: 'changed');

      expect(find.textContaining('Not available'), findsOneWidget);
      await tapText(tester, name);
      expect(h.transfers.started, isEmpty);
    });

    testWidgets('a saved file that left its folder is reported as gone',
        (tester) async {
      h = await RomDropHarness.create();
      await h.useFolder();
      final synthetic = SyntheticBios();
      h.storage.folders[biosFolder.uri]![name] = synthetic.current;
      await h.controller.adoptExisting(
          asset: synthetic.asset, file: synthetic.file, folder: biosFolder);
      h.storage.folders[biosFolder.uri]!.remove(name);
      await open(tester);

      expect(find.textContaining('is no longer there'), findsOneWidget);
      expect(find.text('ON THIS DEVICE'), findsNothing);
      expect(find.textContaining('Imported in my emulator'), findsNothing);
    });

    testWidgets(
        'several files: their folders are shown and X downloads them all',
        (tester) async {
      h = await RomDropHarness.create();
      await h.useFolder();
      final boot = syntheticBytes(512, seed: 21);
      final flash = syntheticBytes(256, seed: 22);
      final asset = SystemAsset.fromJson(assetJson(
        id: 'ast_set0000000000001',
        platformId: 'dreamcast',
        platformName: 'Dreamcast',
        aliases: const [],
        name: 'Synthetic boot set',
        versions: [
          versionJson(
              id: 'ver_set0000000000001',
              assetId: 'ast_set0000000000001',
              label: '1.0',
              preferred: true,
              files: [
                fileJson(boot,
                    id: 'fil_set0000000000001', name: 'dc/synthetic_boot.bin'),
                fileJson(flash,
                    id: 'fil_set0000000000002', name: 'dc/synthetic_flash.bin'),
              ]),
        ],
      ));
      h.transfers.contents
        ..['fil_set0000000000001'] = boot
        ..['fil_set0000000000002'] = flash;
      await h.pump(tester,
          SystemVersionScreen(asset: asset, version: asset.versions.single));

      expect(find.text('dc/synthetic_boot.bin'), findsOneWidget);
      expect(find.text('dc/synthetic_flash.bin'), findsOneWidget);
      expect(find.text('Download all'), findsOneWidget);

      await press(tester, _x);

      expect(h.transfers.started.map((r) => r.file.id),
          ['fil_set0000000000001'],
          reason: 'one transfer at a time');
      expect(find.textContaining('Waiting'), findsOneWidget);

      h.transfers.finish('fil_set0000000000001');
      await tester.pumpAndSettle();
      h.transfers.finish('fil_set0000000000002');
      await tester.pumpAndSettle();

      expect(h.storage.folders[biosFolder.uri]!.keys,
          unorderedEquals(['dc/synthetic_boot.bin', 'dc/synthetic_flash.bin']));
      expect(find.text('ON THIS DEVICE'), findsNWidgets(2));
      expect(find.text('Download all'), findsNothing);
      expect(find.text('Imported in my emulator: not yet'), findsOneWidget);
    });

    testWidgets('a sensitive asset is marked', (tester) async {
      h = await RomDropHarness.create();
      final keys = syntheticBytes(64, seed: 4);
      final asset = SystemAsset.fromJson(assetJson(
        id: 'ast_keys000000000001',
        platformId: 'switch',
        platformName: 'Nintendo Switch',
        kind: 'keys',
        name: 'Synthetic keys',
        sensitive: true,
        versions: [
          versionJson(
              id: 'ver_keys000000000001',
              assetId: 'ast_keys000000000001',
              label: '19.0.1',
              preferred: true,
              files: [fileJson(keys, id: 'fil_keys000000000001', name: 'synthetic.keys')]),
        ],
      ));
      await h.pump(tester,
          SystemVersionScreen(asset: asset, version: asset.versions.single));

      expect(find.text('SENSITIVE'), findsOneWidget);
      expect(find.text('Nintendo Switch · Keys'), findsOneWidget);
    });
  });

  group('Transfers', () {
    SystemFileRequest request(SyntheticBios bios) => SystemFileRequest(
          file: bios.file,
          assetId: bios.asset.id,
          assetName: bios.asset.name,
          platformId: bios.asset.platformId,
          versionLabel: bios.preferred.displayLabel,
          folder: biosFolder,
        );

    testWidgets('empty', (tester) async {
      final h = await RomDropHarness.create();
      await h.pump(tester, const SystemTransfersScreen());

      expect(find.text('Nothing here'), findsOneWidget);
    });

    testWidgets('shows what is running and lets finished entries be cleared',
        (tester) async {
      final h = await RomDropHarness.create();
      final bios = SyntheticBios()..addTo(h);
      await h.useFolder();
      h.controller.downloads.enqueue(request(bios));
      await h.pump(tester, const SystemTransfersScreen());

      expect(find.text('Synthetic BIOS · v3.0'), findsOneWidget);
      expect(find.textContaining('Downloading from RomDrop'), findsOneWidget);
      expect(find.textContaining('Select to cancel'), findsOneWidget);
      expect(find.text('Clear finished'), findsNothing);

      h.transfers.finish(bios.file.id);
      await tester.pumpAndSettle();

      expect(find.textContaining('Saved to ${biosFolder.name}'), findsOneWidget);
      await tapText(tester, 'Clear finished');
      expect(find.text('Nothing here'), findsOneWidget);
    });

    testWidgets('System Files shows the queue while it has entries',
        (tester) async {
      final h = await RomDropHarness.create();
      final bios = SyntheticBios()..addTo(h);
      await h.useFolder();
      h.controller.downloads.enqueue(request(bios));
      await h.pump(tester, const SystemFilesScreen());

      expect(find.text('Transfers'), findsOneWidget);
      expect(find.text('1 in progress'), findsOneWidget);

      await tapText(tester, 'Transfers');
      expect(find.byType(SystemTransfersScreen), findsOneWidget);
      h.transfers.finish(bios.file.id);
      await tester.pumpAndSettle();
    });
  });

  group('Destinations', () {
    testWidgets('the default folder is chosen with the folder picker',
        (tester) async {
      final h = await RomDropHarness.create();
      await h.pump(tester, const SystemDestinationsScreen());

      expect(find.text('Not chosen yet'), findsOneWidget);
      expect(find.textContaining('Android/data'), findsOneWidget);

      h.storage.nextPick = biosFolder;
      await tapText(tester, 'Default folder');

      expect(find.text(biosFolder.name), findsOneWidget);
      expect(h.controller.destinations.defaultFolder!.uri, biosFolder.uri);
    });

    testWidgets('choosing another folder gives the old grant back',
        (tester) async {
      final h = await RomDropHarness.create();
      await h.useFolder();
      await h.pump(tester, const SystemDestinationsScreen());

      const other = SystemFileFolder('tree:other', 'Internal storage/BIOS');
      h.storage.nextPick = other;
      await tapText(tester, 'Default folder');

      expect(find.text(other.name), findsOneWidget);
      expect(h.storage.pickInitialUris.single, biosFolder.uri);
      expect(h.storage.released, [biosFolder.uri]);
    });

    testWidgets('a platform can have a folder of its own, and drop it again',
        (tester) async {
      final h = await RomDropHarness.create();
      await h.useFolder();
      await h.pump(
          tester,
          const SystemDestinationsScreen(
              platformId: 'vita', platformName: 'PlayStation Vita'));

      expect(find.text('PlayStation Vita folder'), findsOneWidget);
      expect(find.text('Uses the default folder'), findsOneWidget);

      const vita = SystemFileFolder('tree:vita', 'Internal storage/Vita3K');
      h.storage.nextPick = vita;
      await tapText(tester, 'PlayStation Vita folder');

      expect(find.text(vita.name), findsOneWidget);
      expect(h.controller.destinations.resolve('vita')!.uri, vita.uri);
      expect(h.controller.destinations.resolve('ps1')!.uri, biosFolder.uri);

      await tapText(tester, 'Use the default folder for PlayStation Vita');

      expect(h.controller.destinations.resolve('vita')!.uri, biosFolder.uri);
      expect(h.storage.released, [vita.uri]);
      expect(find.text('Uses the default folder'), findsOneWidget);
    });

    testWidgets('a folder Android took back is pointed out', (tester) async {
      final h = await RomDropHarness.create();
      await h.useFolder();
      h.storage.revoked.add(biosFolder.uri);
      await h.pump(tester, const SystemDestinationsScreen());

      expect(find.text('Access to a folder was lost'), findsOneWidget);
      expect(find.text('${biosFolder.name}  (access lost; choose it again)'),
          findsOneWidget);
    });
  });
}
