import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/config/provider_config.dart';
import 'romm_api_service.dart';
import 'romm_platform_matcher.dart';

class RetroArrCredentials {
  static const _storage = FlutterSecureStorage();
  static Future<void> save(String sourceId, String key) =>
      _storage.write(key: 'retroarr:$sourceId', value: key);
  static Future<String?> read(String sourceId) =>
      _storage.read(key: 'retroarr:$sourceId');
  static Future<void> remove(String sourceId) =>
      _storage.delete(key: 'retroarr:$sourceId');
}

class RetroArrPlatform {
  final int id;
  final String name;
  final String slug;
  final String folderName;
  final int? igdbId;
  const RetroArrPlatform(
      this.id, this.name, this.slug, this.folderName, this.igdbId);

  factory RetroArrPlatform.fromJson(Map<String, dynamic> json) =>
      RetroArrPlatform(
        (json['id'] as num).toInt(),
        json['name'] as String,
        json['slug'] as String,
        json['folderName'] as String? ?? '',
        (json['igdbPlatformId'] as num?)?.toInt(),
      );

  static Map<String, int> matchSystems(
          Iterable<String> systems, List<RetroArrPlatform> platforms) =>
      RommPlatformMatcher.buildKnownPlatforms(
          systems,
          platforms
              .map((p) => RommPlatform(
                    id: p.id,
                    name: p.name,
                    slug: p.slug,
                    fsSlug: p.folderName,
                    igdbId: p.igdbId,
                    romCount: 0,
                  ))
              .toList());
}

/// Catalog-only client. Credentials are headers, never URL parameters.
class RetroArrApiService {
  final ProviderConfig config;
  final Dio _dio;
  RetroArrApiService(this.config, {Dio? dio}) : _dio = dio ?? Dio();

  static String normalizeUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
          'Enter an HTTP or HTTPS server URL without credentials or query parameters.');
    }
    return uri.toString().replaceFirst(RegExp(r'/+$'), '');
  }

  String get baseUrl => normalizeUrl(config.url ?? '');
  String endpoint(String path) => '$baseUrl/api/v3/$path';

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final key = config.auth?.apiKey ??
        (config.sourceId == null
            ? null
            : await RetroArrCredentials.read(config.sourceId!));
    if (key == null || key.isEmpty) {
      throw StateError('RetroArr API key is required.');
    }
    try {
      final response = await _dio
          .get<dynamic>(
            endpoint(path),
            queryParameters: query,
            options: Options(
                headers: {'X-Api-Key': key},
                followRedirects: false,
                sendTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30)),
          )
          .timeout(const Duration(seconds: 35));
      return response.data;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw StateError('RetroArr rejected the API key.');
      }
      throw StateError(status == null
          ? 'Could not reach RetroArr. Check the server URL and network.'
          : 'RetroArr returned HTTP $status. Check the server URL and API version.');
    }
  }

  Future<List<RetroArrPlatform>> fetchPlatforms() async {
    final data = await get('platform', query: {'enabledOnly': true});
    if (data is! List) {
      throw const FormatException('Expected a RetroArr platform list.');
    }
    return data
        .map((p) =>
            RetroArrPlatform.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchGames(int platformId) async {
    final games = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (var page = 1;; page++) {
      final data = await get('game/paged',
          query: {'platformId': platformId, 'page': page, 'pageSize': 100});
      if (data is! Map ||
          data['items'] is! List ||
          data['totalPages'] is! num) {
        throw const FormatException('Expected a RetroArr paged game list.');
      }
      final items = (data['items'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      for (final item in items) {
        if ((item['platformId'] as num).toInt() != platformId) {
          throw const FormatException(
              'RetroArr returned a game from another platform.');
        }
        if (seen.add((item['id'] as num).toInt())) games.add(item);
      }
      if (page >= (data['totalPages'] as num).toInt()) break;
      if (items.isEmpty || page >= 10000) {
        throw const FormatException('Incomplete RetroArr pagination.');
      }
    }
    return games;
  }

  Future<Map<String, dynamic>> fetchDetails(int id) async =>
      Map<String, dynamic>.from(await get('game/$id') as Map);

  String? artworkUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final base = Uri.parse('$baseUrl/');
    final value = raw.trim();
    // RetroArr emits server-root paths; retain a configured proxy base path.
    final relative = value.startsWith('/') &&
            !value.startsWith('//') &&
            !value.startsWith(base.path)
        ? value.substring(1)
        : value;
    final uri = base.resolve(relative);
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.queryParameters.keys
            .any((k) => ['apikey', 'access_token'].contains(k.toLowerCase()))) {
      return null;
    }
    return uri.toString();
  }
}
