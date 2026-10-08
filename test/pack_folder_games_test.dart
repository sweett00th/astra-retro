import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_eshop/features/onboarding/onboarding_controller.dart';
import 'package:retro_eshop/models/config/app_config.dart';
import 'package:retro_eshop/models/config/system_config.dart';
import 'package:retro_eshop/models/download_item.dart';
import 'package:retro_eshop/models/game_item.dart';
import 'package:retro_eshop/models/system_model.dart';
import 'package:retro_eshop/services/config_storage_service.dart';
import 'package:retro_eshop/services/rom_manager.dart';
import 'package:retro_eshop/utils/game_merge_helper.dart';

final _vita = SystemModel.supportedSystems.firstWhere((s) => s.id == 'psvita');
final _psx = SystemModel.supportedSystems.firstWhere((s) => s.id == 'psx');

/// A folder-based game as a RetroArr source lists it: the folder's name.
const _folderGame = GameItem(
  filename: 'Synthetic Game [PCSX00001]',
  displayName: 'Synthetic Game',
  url: 'http://catalog.example/api/v3/game/7',
  isFolder: true,
);

class _NoStorage extends ConfigStorageService {
  _NoStorage() : super(directoryProvider: _none);

  static Future<Never> _none() => throw UnimplementedError();

  @override
  Future<void> exportConfig(AppConfig config) async {}
}

SystemConfig _config(String id, {bool? packFolders}) => SystemConfig(
      id: id,
      name: id,
      targetFolder: '/roms/$id',
      providers: const [],
      packFolders: packFolders,
    );

void main() {
  group('the per-system setting', () {
    test('Vita packs folder games unless the user turns it off', () {
      expect(_vita.packFolderGames, isTrue);
      expect(_config('psvita').packsFolderGames, isTrue);
      expect(_config('psvita', packFolders: false).packsFolderGames, isFalse);
    });

    test('other systems only pack when the user turns it on', () {
      expect(_psx.packFolderGames, isFalse);
      expect(_config('psx').packsFolderGames, isFalse);
      expect(_config('psx', packFolders: true).packsFolderGames, isTrue);
    });

    test('a config saved before the setting existed follows the default', () {
      final saved = SystemConfig.fromJson({
        'id': 'psvita',
        'name': 'PlayStation Vita',
        'target_folder': '/roms/psvita',
        'providers': const [],
        'auto_extract': false,
      });
      expect(saved.packFolders, isNull);
      expect(saved.packsFolderGames, isTrue);
      expect(saved.toJson().containsKey('pack_folders'), isFalse);
    });

    test('the user\'s choice survives saving and loading', () {
      final choice = _config('psvita', packFolders: false);
      expect(choice.toJson()['pack_folders'], isFalse);
      expect(choice.toJsonWithoutAuth()['pack_folders'], isFalse);
      expect(SystemConfig.fromJson(choice.toJson()).packsFolderGames, isFalse);
      expect(choice.copyWith(name: 'Vita').packFolders, isFalse);
    });

    test('the switch in Settings writes the choice into the system', () {
      final controller = OnboardingController(_NoStorage());
      controller.selectConsole('psvita');
      expect(controller.state.consoleSubState!.packFolders, isNull);
      controller.setTargetFolder('/roms/psvita');
      controller.saveConsoleConfig();
      expect(controller.state.configuredSystems['psvita']!.packsFolderGames,
          isTrue,
          reason: 'untouched, so the Vita default applies');

      controller.selectConsole('psvita');
      controller.setPackFolders(false);
      controller.saveConsoleConfig();
      expect(controller.state.configuredSystems['psvita']!.packFolders, isFalse);

      controller.selectConsole('psvita');
      expect(controller.state.consoleSubState!.packFolders, isFalse,
          reason: 'reopening the system shows what was saved');
    });

    test('a queued download remembers the setting', () {
      final item = DownloadItem(
        id: 'psvita_game',
        game: _folderGame,
        system: _vita,
        targetFolder: '/roms/psvita',
        packFolders: true,
      );
      expect(item.copyWith(status: DownloadStatus.downloading).packFolders,
          isTrue);
      expect(DownloadItem.fromJson(item.toJson(), _vita).packFolders, isTrue);
      final older = Map<String, dynamic>.from(item.toJson())
        ..remove('packFolders');
      expect(DownloadItem.fromJson(older, _vita).packFolders, isFalse);
    });
  });

  group('a packed game in the library', () {
    late Directory library;
    late File packed;
    final roms = RomManager();

    setUp(() {
      library = Directory.systemTemp.createTempSync('pack_folder_games_test_');
      packed = File(p.join(library.path, 'Synthetic Game [PCSX00001].zip'));
    });

    tearDown(() => library.deleteSync(recursive: true));

    test('counts as the installed game', () async {
      expect(await roms.exists(_folderGame, _vita, library.path), isFalse);
      packed.writeAsBytesSync([0x50, 0x4b, 0x05, 0x06]);

      expect(RomManager.packedFilename(_folderGame.filename),
          p.basename(packed.path));
      expect(await roms.exists(_folderGame, _vita, library.path), isTrue);
      expect(
          await RomManager.resolveInstalledPath(
              _folderGame, _vita, library.path),
          '${library.path}/${p.basename(packed.path)}');
      final share =
          await RomManager.resolveSharePath(_folderGame, _vita, library.path);
      expect(share!.isDirectory, isFalse);
      expect(p.basename(share.path), p.basename(packed.path));
    });

    test('is one of the names the game can have on the device', () {
      expect(RomManager.installedNames(_folderGame.filename, _vita),
          [_folderGame.filename, p.basename(packed.path)]);
      // An archive is there as itself or as what was extracted from it.
      expect(RomManager.installedNames('Other Game.zip', _psx), [
        'Other Game.zip',
        'Other Game',
        for (final ext in _psx.romExtensions) 'Other Game$ext',
      ]);
      expect(RomManager.installedNames('Other Game.zip', null),
          ['Other Game.zip', 'Other Game']);
    });

    test('is not listed a second time beside its catalog entry', () async {
      packed.writeAsBytesSync([0x50, 0x4b, 0x05, 0x06]);
      File(p.join(library.path, 'Homebrew.vpk')).writeAsBytesSync([1]);

      final local = await RomManager.scanLocalGames(_vita, library.path);
      expect(local.map((g) => g.filename),
          containsAll([p.basename(packed.path), 'Homebrew.vpk']));

      final merged = GameMergeHelper.merge([_folderGame], local, _vita);
      expect(merged.map((g) => g.filename),
          unorderedEquals([_folderGame.filename, 'Homebrew.vpk']));
    });

    test('is removed with the game, along with a loose copy', () async {
      packed.writeAsBytesSync([0x50, 0x4b, 0x05, 0x06]);
      final loose = Directory(p.join(library.path, _folderGame.filename));
      File(p.join(loose.path, 'eboot.bin'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);

      await roms.delete(_folderGame, _vita, library.path);

      expect(packed.existsSync(), isFalse);
      expect(loose.existsSync(), isFalse);
      expect(await roms.exists(_folderGame, _vita, library.path), isFalse);
    });

    test('a game that is an archive itself is left alone', () async {
      const archived = GameItem(
          filename: 'Other Game.zip', displayName: 'Other Game', url: '');
      File(p.join(library.path, 'Other Game.zip.zip')).writeAsBytesSync([1]);
      expect(await roms.exists(archived, _vita, library.path), isFalse);
    });
  });
}
