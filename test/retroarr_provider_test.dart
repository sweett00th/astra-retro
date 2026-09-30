import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:retro_eshop/models/config/provider_config.dart';
import 'package:retro_eshop/models/config/source.dart';
import 'package:retro_eshop/models/config/system_config.dart';
import 'package:retro_eshop/models/game_item.dart';
import 'package:retro_eshop/models/game_metadata_info.dart';
import 'package:retro_eshop/services/download_handle.dart';
import 'package:retro_eshop/services/providers/retroarr_provider.dart';
import 'package:retro_eshop/services/retroarr_api_service.dart';
import 'package:retro_eshop/services/source_resolver.dart';
import 'package:retro_eshop/utils/friendly_error.dart';

class _Adapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) reply;
  _Adapter(this.reply);
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      reply(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = ProviderConfig(
      type: ProviderType.retroarr,
      priority: 5,
      url: 'http://catalog.example/retroarr',
      sourceId: 'test-source',
      platformId: 42,
      auth: AuthConfig(apiKey: 'test-key'));
  const system = SystemConfig(
      id: 'psx',
      name: 'PlayStation',
      targetFolder: '/unused',
      providers: [config]);

  test('saved sources retrieve keys from secure storage and remove them',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await RetroArrCredentials.save('saved-source', 'secure-test-key');
    const savedConfig = ProviderConfig(
        type: ProviderType.retroarr,
        priority: 5,
        url: 'https://catalog.example',
        sourceId: 'saved-source');
    final dio = Dio()
      ..httpClientAdapter = _Adapter((request) {
        expect(request.headers['X-Api-Key'], 'secure-test-key');
        return _json([]);
      });
    expect(savedConfig.toJson().containsKey('auth'), false);
    expect(await RetroArrApiService(savedConfig, dio: dio).fetchPlatforms(),
        isEmpty);
    await RetroArrCredentials.remove('saved-source');
    expect(await RetroArrCredentials.read('saved-source'), isNull);
    await expectLater(
        RetroArrApiService(savedConfig, dio: dio).fetchPlatforms(),
        throwsA(isA<UserFacingException>()));
  });

  test('detail endpoint maps metadata without requesting files or downloads',
      () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter((request) {
        expect(request.uri.path, '/retroarr/api/v3/game/7');
        return _json({
          'id': 7,
          'overview': 'Stored description',
          'developer': 'Example Studio',
          'publisher': 'Example Publisher',
          'year': 1999,
          'rating': 91,
          'genres': ['Adventure'],
          'releaseDate': '1999-01-01T00:00:00'
        });
      });
    final saved = <GameMetadataInfo>[];
    final provider = RetroArrProvider(config,
        api: RetroArrApiService(config, dio: dio),
        saveMetadata: (_, rows) async => saved.addAll(rows));
    final info = await provider.fetchDetails(
        const GameItem(
            filename: 'test-source-7',
            displayName: 'Example',
            url: 'http://catalog.example/retroarr/api/v3/game/7',
            providerConfig: config),
        'psx');
    expect(info.summary, 'Stored description');
    expect(info.developer, 'Example Studio');
    expect(info.releaseYear, 1999);
    expect(info.releaseDate, '1999-01-01');
    expect(saved.single.filename, 'test-source-7');
  });

  test('protected platform endpoint uses header auth and preserves base path',
      () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter((request) {
        expect(request.uri.path, '/retroarr/api/v3/platform');
        expect(request.queryParameters, {'enabledOnly': true});
        expect(request.headers['X-Api-Key'], 'test-key');
        expect(request.followRedirects, false);
        expect(request.uri.toString(), isNot(contains('test-key')));
        return _json([
          {
            'id': 42,
            'name': 'PlayStation',
            'slug': 'playstation',
            'folderName': 'psx',
            'igdbPlatformId': 7,
            'enabled': true
          }
        ]);
      });
    final platforms =
        await RetroArrApiService(config, dio: dio).fetchPlatforms();
    expect(
        RetroArrPlatform.matchSystems(['psx', 'n3ds'], platforms), {'psx': 42});
  });

  test('all pages map real filenames, covers and metadata', () async {
    final pages = <int>[];
    final dio = Dio()
      ..httpClientAdapter = _Adapter((request) {
        final page = request.queryParameters['page'] as int;
        pages.add(page);
        return _json({
          'page': page,
          'totalPages': 2,
          'items': [
            page == 1
                ? {
                    'id': page,
                    'title': 'Game $page',
                    'platformId': 42,
                    'year': 1998,
                    'coverUrl': '/images/cover.jpg',
                    'rating': 85,
                    'genres': ['Adventure'],
                    'status': 4,
                    'path': '/media/psx/Game 1 (USA).cue'
                  }
                // Unmatched titles: RetroArr sends year 0 and no genres.
                : {
                    'id': page,
                    'title': 'Game $page',
                    'platformId': 42,
                    'year': 0,
                    'genres': [],
                    'status': 4,
                    'path': r'C:\Games\psx\Game 2'
                  },
            // Not downloadable: no files, or files gone missing.
            {'id': 100 + page, 'title': 'Wanted', 'platformId': 42},
            {
              'id': 200 + page,
              'title': 'Gone',
              'platformId': 42,
              'path': '/media/psx/Gone.chd',
              'missingSince': '2026-01-01T00:00:00'
            }
          ]
        });
      });
    final saved = <GameMetadataInfo>[];
    final provider = RetroArrProvider(config,
        api: RetroArrApiService(config, dio: dio),
        saveMetadata: (_, rows) async => saved.addAll(rows),
        loadMetadata: (systemId) async => {
              'Game 1 (USA).cue': GameMetadataInfo(
                  filename: 'Game 1 (USA).cue',
                  systemSlug: systemId,
                  summary: 'Cached description',
                  developer: 'Cached Studio',
                  releaseDate: '1998-03-01',
                  lastUpdated: 0)
            });
    final games = await provider.fetchGames(system);
    expect(pages, [1, 2]);
    expect(games.map((g) => g.filename), ['Game 1 (USA).cue', 'Game 2']);
    expect(games.first.displayName, 'Game 1');
    expect(games.first.cachedCoverUrl,
        'http://catalog.example/retroarr/images/cover.jpg');
    expect(games.last.cachedCoverUrl, isNull);
    expect(games.first.isRetroArr, true);
    expect(saved.single.filename, 'Game 1 (USA).cue');
    expect(saved.single.releaseYear, 1998);
    expect(saved.single.genres, 'Adventure');
    expect(saved.single.summary, 'Cached description');
    expect(saved.single.developer, 'Cached Studio');
    expect(saved.single.releaseDate, '1998-03-01');
  });

  test('invalid credentials and HTML responses do not pass connection test',
      () async {
    for (final response in [
      _json({'error': 'Unauthorized'}, 401),
      ResponseBody.fromString('<html>login</html>', 200)
    ]) {
      final dio = Dio()..httpClientAdapter = _Adapter((_) => response);
      final result = await RetroArrProvider(config,
              api: RetroArrApiService(config, dio: dio))
          .testConnection();
      expect(result.success, false);
      expect(result.error, isNot(contains('test-key')));
    }
  });

  test('empty library is valid and malformed pagination fails', () async {
    final dio = Dio()
      ..httpClientAdapter =
          _Adapter((_) => _json({'items': [], 'totalPages': 0}));
    expect(await RetroArrApiService(config, dio: dio).fetchGames(42), isEmpty);
    dio.httpClientAdapter =
        _Adapter((_) => _json({'items': [], 'totalPages': 2}));
    await expectLater(RetroArrApiService(config, dio: dio).fetchGames(42),
        throwsFormatException);
  });

  test(
      'source round trip and resolver preserve source identity without credentials',
      () {
    final source = Source.fromJson(const Source(
        id: 'catalog',
        name: 'RetroArr',
        type: SourceType.retroarr,
        url: 'http://catalog.example',
        autoMap: true,
        knownPlatforms: {'psx': 42}).toJson());
    final resolved = SourceResolver.providersFor(system, [source]).single;
    expect(resolved.type, ProviderType.retroarr);
    expect(resolved.platformId, 42);
    expect(resolved.sourceId, 'catalog');
    expect(resolved.auth, isNull);
    final cached = GameItem.fromJson(const GameItem(
            filename: 'catalog-1',
            displayName: 'Example',
            url: 'http://catalog.example/api/v3/game/1',
            providerConfig: config)
        .toJson());
    expect(cached.isRetroArr, true);
  });

  test('URLs reject credentials and preserve external artwork without API keys',
      () {
    final api = RetroArrApiService(config);
    expect(api.artworkUrl('https://images.example/cover.jpg'),
        'https://images.example/cover.jpg');
    expect(api.artworkUrl('/image?apiKey=secret'), isNull);
    expect(api.artworkUrl('file:///private/image'), isNull);
    expect(
        () =>
            RetroArrApiService.normalizeUrl('http://user:pass@catalog.example'),
        throwsFormatException);
    expect(
        () => RetroArrApiService.normalizeUrl(
            'http://catalog.example?apiKey=secret'),
        throwsFormatException);
  });

  group('downloads', () {
    GameItem game(String filename) => GameItem(
        filename: filename,
        displayName: 'Game',
        url: 'http://catalog.example/retroarr/api/v3/game/9',
        providerConfig: config);

    RetroArrProvider withFiles(List<Map<String, Object>> files) {
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          expect(request.uri.path, '/retroarr/api/v3/game/9/files');
          expect(request.headers['X-Api-Key'], 'test-key');
          return _json({'files': files});
        });
      return RetroArrProvider(config,
          api: RetroArrApiService(config, dio: dio));
    }

    test('single file uses header auth, no redirects and a size hint',
        () async {
      final handle = await withFiles([
        {'relativePath': 'Game (USA).z64', 'size': 8, 'fileType': 'Main'}
      ]).resolveDownload(game('Game (USA).z64'));
      expect(handle, isA<HttpDownloadHandle>());
      handle as HttpDownloadHandle;
      final uri = Uri.parse(handle.url);
      expect(uri.path, '/retroarr/api/v3/game/9/files/download');
      expect(uri.queryParameters['path'], 'Game (USA).z64');
      expect(handle.url, isNot(contains('test-key')));
      expect(handle.headers, {'X-Api-Key': 'test-key'});
      expect(handle.followRedirects, false);
      expect(handle.expectedBytes, 8);
    });

    test('cue with bin tracks installs flat in the system folder', () async {
      final handle = await withFiles([
        {'relativePath': 'Game.cue', 'size': 1, 'fileType': 'Main'},
        {'relativePath': 'Game (Track 1).bin', 'size': 10, 'fileType': 'Main'},
        {'relativePath': 'Game (Track 2).bin', 'size': 20, 'fileType': 'Main'},
      ]).resolveDownload(game('Game.cue'));
      handle as HttpFolderDownloadHandle;
      expect(handle.subfolder, isNull);
      expect(handle.files.map((f) => f.relativePath),
          ['Game.cue', 'Game (Track 1).bin', 'Game (Track 2).bin']);
      expect(handle.totalBytes, 31);
      expect(handle.followRedirects, false);
      expect(handle.resumeKey, 'test-source_9');
    });

    test('folder game keeps its folder and skips patches and DLC', () async {
      final handle = await withFiles([
        {'relativePath': 'eboot.bin', 'size': 1, 'fileType': 'Main'},
        {'relativePath': 'sce_sys/param.sfo', 'size': 2, 'fileType': 'Main'},
        {'relativePath': 'update.pkg', 'size': 3, 'fileType': 'Patch'},
      ]).resolveDownload(game('Game Folder'));
      handle as HttpFolderDownloadHandle;
      expect(handle.subfolder, 'Game Folder');
      expect(handle.files.map((f) => f.relativePath),
          ['eboot.bin', 'sce_sys/param.sfo']);
    });

    test('a game without files explains how to fix it', () async {
      // The queue shows this text instead of a generic error.
      expect(getUserFriendlyError(const UserFacingException('Rescan it')),
          'Rescan it');
      await expectLater(
          withFiles([]).resolveDownload(game('Game.z64')),
          throwsA(isA<UserFacingException>()
              .having((e) => e.message, 'message', contains('Rescan'))));
    });
  });

  group('library scan', () {
    test('trigger posts to media/scan and explains missing IGDB', () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          expect(request.method, 'POST');
          expect(request.uri.path, '/retroarr/api/v3/media/scan');
          expect(request.headers['X-Api-Key'], 'test-key');
          return _json(
              {'success': false, 'errorCode': 'IGDB_NOT_CONFIGURED'}, 400);
        });
      await expectLater(
          RetroArrApiService(config, dio: dio).triggerScan(),
          throwsA(isA<UserFacingException>()
              .having((e) => e.message, 'message', contains('IGDB'))));
    });

    test('follows a running scan until it finishes', () async {
      var polls = 0;
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          if (request.method == 'POST') return _json({'message': 'started'});
          expect(request.uri.path, '/retroarr/api/v3/media/scan/status');
          polls++;
          return _json({
            'isScanning': polls < 3,
            'gamesAddedCount': polls,
            'lastGameFound': 'Game $polls'
          });
        });
      final statuses = await scanRetroArrLibrary(
              RetroArrApiService(config, dio: dio),
              poll: Duration.zero)
          .toList();
      expect(statuses.map((s) => s.isScanning), [true, true, false]);
      expect(statuses.last.gamesAdded, 3);
    });

    test('a scan that ends before the first poll still reports', () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) => request.method == 'POST'
            ? _json({})
            : _json({'isScanning': false, 'gamesAddedCount': 2}));
      final statuses = await scanRetroArrLibrary(
              RetroArrApiService(config, dio: dio),
              poll: Duration.zero,
              startGrace: Duration.zero)
          .toList();
      expect(statuses.single.gamesAdded, 2);
    });
  });
}
