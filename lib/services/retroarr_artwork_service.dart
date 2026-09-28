import 'dart:io';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../models/config/source.dart';
import 'config_storage_service.dart';
import 'retroarr_api_service.dart';

/// Authenticate only configured RetroArr origins. Do not forward keys on redirects.
class RetroArrArtworkService {
  static Future<FileServiceResponse?> fetch(String url) async {
    final uri = Uri.parse(url);
    if (!uri.path.contains('/api/')) return null;
    final config = await ConfigStorageService().loadConfig();
    if (config == null) return null;
    for (final source in config.sources) {
      if (source.type != SourceType.retroarr ||
          !source.enabled ||
          source.url == null) {
        continue;
      }
      final base =
          Uri.parse('${RetroArrApiService.normalizeUrl(source.url!)}/');
      if (uri.origin != base.origin ||
          !uri.path.startsWith('${base.path}api/')) {
        continue;
      }
      final key = await RetroArrCredentials.read(source.id);
      if (key == null) {
        throw const HttpException('RetroArr artwork credentials are missing.');
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final request =
            await client.getUrl(uri).timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        request.headers.set('X-Api-Key', key);
        final response =
            await request.close().timeout(const Duration(seconds: 30));
        final bytes = await response.fold<List<int>>(
            [], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 30));
        return _ArtworkResponse(response.statusCode, bytes,
            response.headers.contentType?.subType ?? 'jpg');
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }
}

class _ArtworkResponse implements FileServiceResponse {
  @override
  final int statusCode;
  final List<int> bytes;
  @override
  final String fileExtension;
  _ArtworkResponse(this.statusCode, this.bytes, this.fileExtension);
  @override
  Stream<List<int>> get content => Stream.value(bytes);
  @override
  int get contentLength => bytes.length;
  @override
  String? get eTag => null;
  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 1));
}
