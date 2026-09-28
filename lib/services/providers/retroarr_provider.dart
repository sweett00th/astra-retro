import '../../models/config/provider_config.dart';
import '../../models/config/system_config.dart';
import '../../models/game_item.dart';
import '../../models/game_metadata_info.dart';
import '../database_service.dart';
import '../download_handle.dart';
import '../retroarr_api_service.dart';
import '../source_provider.dart';

class RetroArrProvider implements SourceProvider {
  @override
  final ProviderConfig config;
  final RetroArrApiService _api;
  final Future<void> Function(String, List<GameMetadataInfo>) _saveMetadata;
  final Future<Map<String, GameMetadataInfo>> Function(String) _loadMetadata;
  RetroArrProvider(this.config,
      {RetroArrApiService? api,
      Future<void> Function(String, List<GameMetadataInfo>)? saveMetadata,
      Future<Map<String, GameMetadataInfo>> Function(String)? loadMetadata})
      : _api = api ?? RetroArrApiService(config),
        _saveMetadata = saveMetadata ?? DatabaseService().saveGameMetadata,
        _loadMetadata = loadMetadata ?? DatabaseService().getMetadataForSystem;

  // RetroArr sends year 0 when unknown and full DateTime strings; the detail
  // UI expects a real year and a YYYY-MM-DD date, as the RomM provider stores.
  static int? _year(Object? value) {
    final year = (value as num?)?.toInt();
    return year != null && year > 0 ? year : null;
  }

  static String? _date(Object? value) =>
      value is String ? RegExp(r'^\d{4}-\d{2}-\d{2}').stringMatch(value) : null;

  static String? _genres(Object? value) =>
      value is List && value.isNotEmpty ? value.join(', ') : null;

  @override
  String get displayLabel => 'RetroArr';

  @override
  Future<SourceConnectionResult> testConnection() async {
    try {
      await _api.fetchPlatforms();
      return const SourceConnectionResult.ok();
    } catch (e) {
      return SourceConnectionResult.failed(e.toString());
    }
  }

  @override
  Future<List<GameItem>> fetchGames(SystemConfig system) async {
    final platformId = config.platformId;
    if (platformId == null) {
      throw StateError('RetroArr platform is not mapped.');
    }
    final rows = await _api.fetchGames(platformId);
    // Catalog rows lack the detail fields; keep those cached from earlier
    // detail fetches instead of replacing them with empty values.
    final cached = await _loadMetadata(system.id);
    final games = <GameItem>[];
    final metadata = <GameMetadataInfo>[];
    for (final row in rows) {
      final id = (row['id'] as num).toInt();
      final filename = '${config.sourceId ?? 'retroarr'}-$id';
      games.add(GameItem(
          filename: filename,
          displayName: row['title'] as String,
          url: _api.endpoint('game/$id'),
          cachedCoverUrl: _api.artworkUrl(row['coverUrl'] as String?),
          providerConfig: config));
      final previous = cached[filename];
      final info = GameMetadataInfo(
          filename: filename,
          systemSlug: system.id,
          summary: previous?.summary,
          developer: previous?.developer,
          publisher: previous?.publisher,
          releaseDate: previous?.releaseDate,
          genres: _genres(row['genres']),
          releaseYear: _year(row['year']),
          rating: (row['rating'] as num?)?.toDouble(),
          lastUpdated: DateTime.now().millisecondsSinceEpoch);
      if (info.hasContent) metadata.add(info);
    }
    await _saveMetadata(system.id, metadata);
    return games;
  }

  @override
  Future<DownloadHandle> resolveDownload(GameItem game) =>
      Future.error(UnsupportedError('RetroArr is read-only in Milestone 1'));

  Future<GameMetadataInfo> fetchDetails(GameItem game, String systemId) async {
    final id = int.parse(Uri.parse(game.url).pathSegments.last);
    final row = await _api.fetchDetails(id);
    final info = GameMetadataInfo(
        filename: game.filename,
        systemSlug: systemId,
        summary: row['overview'] as String?,
        developer: row['developer'] as String?,
        publisher: row['publisher'] as String?,
        genres: _genres(row['genres']),
        releaseYear: _year(row['year']),
        releaseDate: _date(row['releaseDate']),
        rating: (row['rating'] as num?)?.toDouble(),
        lastUpdated: DateTime.now().millisecondsSinceEpoch);
    await _saveMetadata(systemId, [info]);
    return info;
  }
}
