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
import 'package:retro_eshop/services/providers/retroarr_provider.dart';
import 'package:retro_eshop/services/retroarr_api_service.dart';
import 'package:retro_eshop/services/source_resolver.dart';

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
        throwsStateError);
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

  test('all pages map stable IDs, covers and metadata without install state',
      () async {
    final pages = <int>[];
    final dio = Dio()
      ..httpClientAdapter = _Adapter((request) {
        final page = request.queryParameters['page'] as int;
        pages.add(page);
        return _json({
          'page': page,
          'totalPages': 2,
          'items': [
            {
              'id': page,
              'title': 'Game $page',
              'platformId': 42,
              'year': 1998,
              'coverUrl': '/images/cover.jpg',
              'rating': 85,
              'genres': ['Adventure'],
              'status': 'Downloaded'
            }
          ]
        });
      });
    final saved = <GameMetadataInfo>[];
    final provider = RetroArrProvider(config,
        api: RetroArrApiService(config, dio: dio),
        saveMetadata: (_, rows) async => saved.addAll(rows));
    final games = await provider.fetchGames(system);
    expect(pages, [1, 2]);
    expect(games.map((g) => g.filename), ['test-source-1', 'test-source-2']);
    expect(games.first.displayName, 'Game 1');
    expect(games.first.cachedCoverUrl,
        'http://catalog.example/retroarr/images/cover.jpg');
    expect(games.first.isReadOnly, true);
    expect(saved.first.releaseYear, 1998);
    expect(saved.first.genres, 'Adventure');
    await expectLater(
        provider.resolveDownload(games.first), throwsUnsupportedError);
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
    expect(cached.isReadOnly, true);
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
}
