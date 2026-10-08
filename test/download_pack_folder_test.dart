// Real loopback HTTP: this file must not initialise the Flutter test binding,
// which replaces HttpClient with one that answers 400.
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:retro_eshop/models/config/provider_config.dart';
import 'package:retro_eshop/models/download_item.dart';
import 'package:retro_eshop/models/game_item.dart';
import 'package:retro_eshop/models/system_model.dart';
import 'package:retro_eshop/services/download_service.dart';
import 'package:retro_eshop/services/native_smb_service.dart';
import 'package:retro_eshop/services/rom_manager.dart';

import 'folder_packer_test.dart' show syntheticBytes;
import 'helpers/romdrop_fakes.dart' show FixtureServer, respondJson;

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.tempPath);

  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

const _folderName = 'Synthetic Game [PCSX00001]';
const _apiKey = 'synthetic-api-key';

void main() {
  final vita = SystemModel.supportedSystems.firstWhere((s) => s.id == 'psvita');
  final files = {
    'PCSX00001/eboot.bin': syntheticBytes(250000, seed: 1),
    'PCSX00001/sce_sys/param.sfo': syntheticBytes(700, seed: 2),
  };

  late Directory tmp;
  late Directory cache;
  late String library;
  late FixtureServer server;
  late DownloadService service;
  late GameItem game;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('download_pack_folder_test_');
    cache = Directory(p.join(tmp.path, 'cache'))..createSync();
    library = p.join(tmp.path, 'roms', 'psvita');
    PathProviderPlatform.instance = _FakePathProvider(cache.path);

    // A stand-in for RetroArr: one folder-based game with two files.
    server = await FixtureServer.start();
    server.handler = (request) async {
      if (request.headers.value('x-api-key') != _apiKey) {
        return respondJson(request, 401, {'error': 'Missing or invalid API key.'});
      }
      if (request.uri.path == '/api/v3/game/7/files') {
        return respondJson(request, 200, {
          'files': [
            for (final entry in files.entries)
              {
                'relativePath': entry.key,
                'size': entry.value.length,
                'fileType': 'Main',
              },
          ],
        });
      }
      final bytes = files[request.uri.queryParameters['path']];
      if (request.uri.path == '/api/v3/game/7/files/download' && bytes != null) {
        request.response
          ..statusCode = 200
          ..contentLength = bytes.length
          ..add(bytes);
        return request.response.close();
      }
      return respondJson(request, 404, {'error': 'Not found.'});
    };

    game = GameItem(
      filename: _folderName,
      displayName: 'Synthetic Game',
      url: '${server.url}/api/v3/game/7',
      isFolder: true,
      providerConfig: ProviderConfig(
        type: ProviderType.retroarr,
        priority: 0,
        url: server.url,
        auth: const AuthConfig(apiKey: _apiKey),
      ),
    );
    service = DownloadService(NativeSmbService());
  });

  tearDown(() async {
    service.dispose();
    await server.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a just-closed file for a moment; the OS clears temp.
    }
  });

  Future<List<DownloadProgress>> download({required bool packFolders}) =>
      service
          .downloadGameStream(game, library, vita, packFolders: packFolders)
          .toList();

  test('a folder game is saved as one .zip when the system packs folders',
      () async {
    final progress = await download(packFolders: true);

    expect(progress.last.status, DownloadStatus.completed,
        reason: '${progress.last.error}');
    expect(progress.map((p) => p.status), contains(DownloadStatus.moving));

    final zip = File(p.join(library, '$_folderName.zip'));
    expect(zip.existsSync(), isTrue);
    expect(Directory(library).listSync().map((e) => p.basename(e.path)),
        ['$_folderName.zip'],
        reason: 'no loose folder and no partial archive beside it');

    final input = InputFileStream(zip.path);
    final packed = {
      for (final file in ZipDecoder().decodeBuffer(input).files)
        if (file.isFile) file.name: file.content as List<int>,
    };
    await input.close();
    expect(packed.keys.toSet(),
        {for (final name in files.keys) '$_folderName/$name'});
    for (final entry in files.entries) {
      expect(packed['$_folderName/${entry.key}'], entry.value,
          reason: entry.key);
    }

    expect(await RomManager().exists(game, vita, library), isTrue);
    expect(cache.listSync(), isEmpty,
        reason: 'the downloaded files are gone once they are packed');
    expect(server.requests.every((r) => !r.uri.toString().contains(_apiKey)),
        isTrue);
  });

  test('with the setting off the folder is installed as before', () async {
    final progress = await download(packFolders: false);

    expect(progress.last.status, DownloadStatus.completed,
        reason: '${progress.last.error}');
    expect(File(p.join(library, '$_folderName.zip')).existsSync(), isFalse);
    for (final entry in files.entries) {
      final installed =
          File(p.joinAll([library, _folderName, ...entry.key.split('/')]));
      expect(installed.readAsBytesSync(), entry.value, reason: entry.key);
    }
  });

  test('a download that fails part-way leaves no archive behind', () async {
    files['PCSX00001/missing.bin'] = syntheticBytes(10);
    final inner = server.handler;
    server.handler = (request) async {
      if (request.uri.queryParameters['path'] == 'PCSX00001/missing.bin') {
        return respondJson(request, 404, {'error': 'Not found.'});
      }
      return inner(request);
    };
    addTearDown(() => files.remove('PCSX00001/missing.bin'));

    final progress = await download(packFolders: true);

    expect(progress.last.status, DownloadStatus.error);
    expect(Directory(library).existsSync() ? Directory(library).listSync() : [],
        isEmpty);
  });
}
