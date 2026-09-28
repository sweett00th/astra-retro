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
  RetroArrProvider(this.config,
      {RetroArrApiService? api,
      Future<void> Function(String, List<GameMetadataInfo>)? saveMetadata})
      : _api = api ?? RetroArrApiService(config),
        _saveMetadata = saveMetadata ?? DatabaseService().saveGameMetadata;

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
      metadata.add(GameMetadataInfo(
          filename: filename,
          systemSlug: system.id,
          genres: (row['genres'] as List?)?.join(', '),
          releaseYear: (row['year'] as num?)?.toInt(),
          rating: (row['rating'] as num?)?.toDouble(),
          lastUpdated: DateTime.now().millisecondsSinceEpoch));
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
        genres: (row['genres'] as List?)?.join(', '),
        releaseYear: (row['year'] as num?)?.toInt(),
        releaseDate: row['releaseDate'] as String?,
        rating: (row['rating'] as num?)?.toDouble(),
        lastUpdated: DateTime.now().millisecondsSinceEpoch);
    await _saveMetadata(systemId, [info]);
    return info;
  }
}
