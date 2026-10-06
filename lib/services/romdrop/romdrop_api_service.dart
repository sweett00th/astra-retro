import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../models/romdrop_models.dart';
import '../../utils/friendly_error.dart';

/// Why a RomDrop request failed, so screens can show the right state.
enum RomDropErrorKind {
  notConfigured,
  offline,
  certificate,
  unauthorized,
  sensitiveNotAllowed,
  insecureTransport,
  forbidden,
  notFound,
  fileUnavailable,
  libraryOffline,
  rateLimited,
  server,
  invalidResponse,
}

class RomDropException extends UserFacingException {
  const RomDropException(this.kind, super.message, {this.fingerprint});

  final RomDropErrorKind kind;

  /// SHA-256 of the certificate the server presented, for [certificate].
  final String? fingerprint;

  /// A later attempt may succeed without the user changing anything.
  bool get retryable =>
      kind == RomDropErrorKind.offline || kind == RomDropErrorKind.server;
}

class RomDropPairing {
  final String token;
  final String deviceId;
  final String deviceName;
  final bool canSensitive;
  const RomDropPairing(
      this.token, this.deviceId, this.deviceName, this.canSensitive);
}

/// Client for RomDrop's system-file API.
///
/// The device token travels only in the Authorization header, never in a URL,
/// and requests refuse redirects so it cannot follow one to another host. A
/// self-signed server certificate is accepted only when its SHA-256
/// fingerprint equals the one the user confirmed; validation is never
/// switched off.
class RomDropApiService {
  RomDropApiService({
    required String baseUrl,
    required this.token,
    this.pinnedFingerprint,
    Dio? dio,
  })  : baseUrl = normalizeUrl(baseUrl),
        _dio = dio ?? _pinnedDio(pinnedFingerprint);

  final String baseUrl;
  final String token;
  final String? pinnedFingerprint;
  final Dio _dio;

  static const tokenPrefix = 'rdt_';

  static String normalizeUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
          'Enter the RomDrop address, for example https://192.168.1.10:3002');
    }
    return uri.toString().replaceFirst(RegExp(r'/+$'), '');
  }

  /// "AB:CD:…" without separators or case, for comparison.
  static String canonicalFingerprint(String value) =>
      value.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();

  static String formatFingerprint(String value) {
    final hex = canonicalFingerprint(value);
    return [
      for (var i = 0; i + 2 <= hex.length; i += 2) hex.substring(i, i + 2)
    ].join(':');
  }

  /// The fingerprint in rows of eight bytes: easier to compare by eye than
  /// one long line that wraps wherever the screen ends.
  static String fingerprintBlock(String value) {
    final bytes = formatFingerprint(value).split(':');
    return [
      for (var i = 0; i < bytes.length; i += 8)
        bytes.skip(i).take(8).join(':')
    ].join('\n');
  }

  static String fingerprintOf(X509Certificate certificate) =>
      formatFingerprint(sha256.convert(certificate.der).toString());

  /// An HttpClient that trusts publicly valid certificates and, in addition,
  /// exactly the pinned one. Also used for downloads.
  static HttpClient httpClient(String? pinnedFingerprint) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(minutes: 5);
    final pin = pinnedFingerprint == null
        ? null
        : canonicalFingerprint(pinnedFingerprint);
    client.badCertificateCallback = (certificate, host, port) =>
        pin != null &&
        pin.isNotEmpty &&
        canonicalFingerprint(fingerprintOf(certificate)) == pin;
    return client;
  }

  static Dio _pinnedDio(String? pinnedFingerprint) {
    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => httpClient(pinnedFingerprint));
    return dio;
  }

  /// Connects once and reports the fingerprint of a certificate the device
  /// does not trust by itself. Null when the certificate is publicly valid
  /// or the address is plain HTTP.
  static Future<String?> untrustedFingerprint(String baseUrl) async {
    final uri = Uri.parse(normalizeUrl(baseUrl));
    if (uri.scheme != 'https') return null;
    String? seen;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    client.badCertificateCallback = (certificate, host, port) {
      seen = fingerprintOf(certificate);
      return false; // only looking; nothing is sent over this connection
    };
    try {
      final request = await client.getUrl(uri.replace(path: '/healthz'));
      final response = await request.close();
      await response.drain<void>();
      return null;
    } on HandshakeException {
      return seen;
    } on SocketException {
      throw const RomDropException(RomDropErrorKind.offline,
          'Could not reach RomDrop. Check the address and your network.');
    } finally {
      client.close(force: true);
    }
  }

  Map<String, String> get authHeaders => {'Authorization': 'Bearer $token'};

  Uri downloadUri(SystemFileInfo file) => Uri.parse('$baseUrl${file.downloadPath}');

  // --------------------------------------------------------------- requests

  static RomDropException _failure(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    final error = data is Map ? data['error'] : null;
    final code = error is Map ? error['code'] as String? : null;
    final message = error is Map ? error['message'] as String? : null;
    if (status == null) {
      final cause = e.error;
      if (cause is HandshakeException ||
          cause is TlsException ||
          e.type == DioExceptionType.badCertificate) {
        return const RomDropException(RomDropErrorKind.certificate,
            'RomDrop presented a certificate this device has not accepted. Open Settings > RomDrop and check the connection.');
      }
      return const RomDropException(RomDropErrorKind.offline,
          'Could not reach RomDrop. Check that the server is on and you are on the same network.');
    }
    return errorFor(status, code: code, message: message);
  }

  /// What a refusal from RomDrop means, from its HTTP status and the error
  /// code in its answer. API requests and downloads share it.
  static RomDropException errorFor(int status, {String? code, String? message}) {
    switch (code) {
      case 'sensitive_permission_required':
        return const RomDropException(RomDropErrorKind.sensitiveNotAllowed,
            'This device is not allowed to get sensitive files. Allow it in RomDrop under Devices.');
      case 'insecure_transport':
        return const RomDropException(RomDropErrorKind.insecureTransport,
            'RomDrop only sends sensitive files over HTTPS. Connect with an https:// address.');
      case 'file_changed':
      case 'file_missing':
        return RomDropException(RomDropErrorKind.fileUnavailable,
            message ?? 'This file is not available on the server right now.');
      case 'storage_unavailable':
      case 'database_unavailable':
        return RomDropException(RomDropErrorKind.libraryOffline,
            message ?? 'RomDrop\'s system-file library is offline.');
      case 'rate_limited':
        return const RomDropException(RomDropErrorKind.rateLimited,
            'Too many failed attempts. Wait a few minutes and try again.');
      case 'invalid_pairing_code':
        return const RomDropException(RomDropErrorKind.unauthorized,
            'That pairing code is wrong, already used or expired. Create a new one in RomDrop under Devices.');
    }
    if (status == 401) {
      return const RomDropException(RomDropErrorKind.unauthorized,
          'RomDrop no longer accepts this device. Pair it again under Settings > RomDrop.');
    }
    if (status == 403) {
      return RomDropException(RomDropErrorKind.forbidden,
          message ?? 'RomDrop refused this request.');
    }
    if (status == 404) {
      return const RomDropException(RomDropErrorKind.notFound,
          'RomDrop no longer has this item. Refresh the list.');
    }
    if (status == 409) {
      return RomDropException(RomDropErrorKind.fileUnavailable,
          message ?? 'This file is not available on the server right now.');
    }
    if (status >= 500) {
      return RomDropException(RomDropErrorKind.server,
          message ?? 'RomDrop returned an error (HTTP $status).');
    }
    // Includes redirects, which are never followed.
    return RomDropException(RomDropErrorKind.forbidden,
        message ?? 'RomDrop refused this request (HTTP $status).');
  }

  static Future<T> _send<T>(
    Dio dio,
    String method,
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    Object? body,
    required T Function(Map<String, dynamic>) parse,
  }) async {
    try {
      final response = await dio
          .request<dynamic>(
            url,
            queryParameters: query,
            data: body,
            options: Options(
              method: method,
              headers: headers,
              contentType: body == null ? null : Headers.jsonContentType,
              responseType: ResponseType.json,
              followRedirects: false,
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ),
          )
          .timeout(const Duration(seconds: 40));
      final data = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (data is! Map) {
        throw const FormatException('Unexpected answer.');
      }
      return parse(Map<String, dynamic>.from(data));
    } on DioException catch (e) {
      throw _failure(e);
    } on TimeoutException {
      throw const RomDropException(
          RomDropErrorKind.offline, 'RomDrop did not answer in time.');
    } on FormatException catch (e) {
      throw RomDropException(RomDropErrorKind.invalidResponse,
          'RomDrop sent an answer this app does not understand (${e.message}). Check the address and that both are up to date.');
    }
  }

  Future<T> _get<T>(String path,
          {Map<String, dynamic>? query,
          required T Function(Map<String, dynamic>) parse}) =>
      _send(_dio, 'GET', '$baseUrl$path',
          headers: authHeaders, query: query, parse: parse);

  /// Also the connection test: an invalid or revoked device gets
  /// [RomDropErrorKind.unauthorized].
  Future<RomDropCapabilities> capabilities() => _get('/api/v1/capabilities',
      parse: (json) {
        final capabilities = RomDropCapabilities.fromJson(json);
        if (capabilities.apiVersion != 'v1') {
          throw FormatException('API ${capabilities.apiVersion}');
        }
        return capabilities;
      });

  Future<List<SystemPlatform>> platforms() => _get('/api/v1/system/platforms',
      parse: (json) => [
            for (final item in (json['items'] as List? ?? const []))
              SystemPlatform.fromJson(Map<String, dynamic>.from(item as Map))
          ]);

  Future<RomDropAssetPage> assetPage(
          {String? platform, SystemFileKind? kind, String? cursor, int limit = 100}) =>
      _get('/api/v1/system/assets',
          query: {
            if (platform != null) 'platform': platform,
            if (kind != null) 'kind': kind.id,
            if (cursor != null) 'cursor': cursor,
            'limit': limit,
          },
          parse: RomDropAssetPage.fromJson);

  /// Every asset of a platform and kind, following the server's pages.
  Future<List<SystemAsset>> assets(
      {required String platform, required SystemFileKind kind}) async {
    final all = <SystemAsset>[];
    String? cursor;
    for (var page = 0; page < 100; page++) {
      final result =
          await assetPage(platform: platform, kind: kind, cursor: cursor);
      all.addAll(result.items);
      cursor = result.nextCursor;
      if (cursor == null) return all;
    }
    throw const RomDropException(
        RomDropErrorKind.invalidResponse, 'RomDrop kept sending more pages.');
  }

  Future<SystemAsset> asset(String id) =>
      _get('/api/v1/system/assets/$id', parse: SystemAsset.fromJson);

  /// Exchanges a one-time pairing code for this device's own credential.
  static Future<RomDropPairing> pair({
    required String baseUrl,
    required String code,
    required String deviceName,
    String? pinnedFingerprint,
    Dio? dio,
  }) =>
      _send(
        dio ?? _pinnedDio(pinnedFingerprint),
        'POST',
        '${normalizeUrl(baseUrl)}/api/v1/devices/pair',
        body: {'code': code, 'device_name': deviceName},
        parse: (json) {
          final device = json['device'];
          final token = json['token'];
          if (token is! String ||
              !token.startsWith(tokenPrefix) ||
              device is! Map) {
            throw const FormatException('No device credential.');
          }
          final permissions = device['permissions'];
          return RomDropPairing(
            token,
            device['id'] as String? ?? '',
            device['name'] as String? ?? deviceName,
            permissions is Map && permissions['sensitive'] == true,
          );
        },
      );
}
