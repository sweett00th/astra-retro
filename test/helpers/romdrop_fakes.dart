import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:retro_eshop/models/romdrop_models.dart';
import 'package:retro_eshop/services/romdrop/romdrop_api_service.dart';
import 'package:retro_eshop/services/romdrop/system_file_download_manager.dart';
import 'package:retro_eshop/services/romdrop/system_file_storage.dart';

/// Stand-in device credential. Not a credential of any real server.
const testToken = 'rdt_TEST-ONLY-not-a-real-token-0000000000000';

/// A copy of one of RomDrop's documented API examples (its
/// docs/api/examples), so the client is held to what the server documents.
Map<String, dynamic> romDropExample(String name) =>
    jsonDecode(File('test/fixtures/romdrop/$name').readAsStringSync())
        as Map<String, dynamic>;

/// Made-up bytes standing in for a system file. Never a real BIOS, firmware
/// image or key.
List<int> syntheticBytes(int length, {int seed = 7}) =>
    List<int>.generate(length, (i) => (i * 31 + seed) % 251);

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

// ------------------------------------------------------------ server-shaped

/// [name] may carry folders ("dc/synthetic.bin"), as a version on the server
/// can.
Map<String, dynamic> fileJson(
  List<int> bytes, {
  required String id,
  String versionId = 'ver_test000000000001',
  String name = 'synthetic-bios.bin',
  String state = 'ok',
  bool extract = false,
}) {
  final sha = sha256Hex(bytes);
  return {
    'id': id,
    'version_id': versionId,
    'filename': name.split('/').last,
    'relative_path': name,
    'size': bytes.length,
    'sha256': sha,
    'etag': '"sha256-$sha"',
    'status': {'inventoried': true, 'hash_verified': true, 'state': state},
    'transfer': {'mode': 'file', 'extract': extract},
    'download_path': '/api/v1/system/files/$id/download',
  };
}

SystemFileInfo systemFile(
  List<int> bytes, {
  String id = 'fil_test000000000001',
  String versionId = 'ver_test000000000001',
  String name = 'synthetic-bios.bin',
  String state = 'ok',
  bool extract = false,
}) =>
    SystemFileInfo.fromJson(fileJson(bytes,
        id: id, versionId: versionId, name: name, state: state, extract: extract));

Map<String, dynamic> versionJson({
  required String id,
  required String assetId,
  String label = '',
  bool preferred = false,
  bool pinned = false,
  bool deprecated = false,
  String notes = '',
  String createdAt = '2026-10-05T20:00:08Z',
  required List<Map<String, dynamic>> files,
}) =>
    {
      'id': id,
      'asset_id': assetId,
      'label': label,
      'label_known': label.isNotEmpty,
      'state': 'active',
      'preferred': preferred,
      'pinned': pinned,
      'deprecated': deprecated,
      'notes': notes,
      'created_at': createdAt,
      'size': files.fold<int>(0, (sum, file) => sum + (file['size'] as int)),
      'file_count': files.length,
      'files': files,
    };

Map<String, dynamic> assetJson({
  required String id,
  String platformId = 'ps1',
  String platformName = 'PlayStation',
  List<String> aliases = const ['psx', 'playstation'],
  String kind = 'bios',
  required String name,
  bool sensitive = false,
  String region = '',
  String model = '',
  String notes = '',
  String installMethod = '',
  String guidance = '',
  required List<Map<String, dynamic>> versions,
  bool withVersions = true,
}) {
  final preferred = versions.where((v) => v['preferred'] == true).firstOrNull;
  return {
    'id': id,
    'content_class': 'system_file',
    'platform': {'id': platformId, 'name': platformName, 'aliases': aliases},
    'kind': kind,
    'name': name,
    'sensitive': sensitive,
    'region': region,
    'model': model,
    'notes': notes,
    'install_method': installMethod,
    'guidance': guidance,
    'preferred_version_id': preferred?['id'],
    'version_count': versions.length,
    'preferred_version': preferred,
    if (withVersions) 'versions': versions,
  };
}

// ------------------------------------------------------------------ storage

/// In-memory stand-in for folders granted through Android's folder picker.
class FakeSystemFileStorage implements SystemFileStorage {
  /// Granted folders: uri → path below it ("name" or "dir/name") → bytes.
  final Map<String, Map<String, List<int>>> folders = {};

  /// Folders whose grant Android has withdrawn.
  final Set<String> revoked = {};

  /// What the folder picker returns next; null is the user backing out.
  SystemFileFolder? nextPick;
  final List<String?> pickInitialUris = [];
  final List<String> released = [];
  final List<({String folderUri, String name, bool replace})> saves = [];
  final List<String> deleted = [];

  /// While set, a save waits here until it is completed or cancelled.
  Completer<void>? saveGate;

  /// The copy lands in the folder with a flipped byte.
  bool corruptOnSave = false;

  final _progress = StreamController<CopyProgress>.broadcast();
  final _inFlight = <String>{};
  final _cancelled = <String>{};

  String documentUri(String folderUri, String name) =>
      '$folderUri/document/$name';

  (String, String)? _locate(String documentUri) {
    for (final folder in folders.entries) {
      for (final name in folder.value.keys) {
        if (this.documentUri(folder.key, name) == documentUri) {
          return (folder.key, name);
        }
      }
    }
    return null;
  }

  void _requireGrant(String folderUri) {
    if (revoked.contains(folderUri) || !folders.containsKey(folderUri)) {
      throw PlatformException(
          code: 'NO_ACCESS', message: 'Access to this folder was withdrawn.');
    }
  }

  @override
  Future<SystemFileFolder?> pickFolder({String? initialUri}) async {
    pickInitialUris.add(initialUri);
    final picked = nextPick;
    if (picked != null) {
      folders.putIfAbsent(picked.uri, () => {});
      revoked.remove(picked.uri);
    }
    return picked;
  }

  @override
  Future<bool> canWrite(String folderUri) async =>
      folders.containsKey(folderUri) && !revoked.contains(folderUri);

  @override
  Future<void> release(String folderUri) async => released.add(folderUri);

  @override
  Future<StoredDocument?> find(String folderUri, String name,
      {List<String> path = const []}) async {
    _requireGrant(folderUri);
    name = [...path, name].join('/');
    final bytes = folders[folderUri]![name];
    return bytes == null
        ? null
        : StoredDocument(documentUri(folderUri, name), bytes.length);
  }

  @override
  Future<StoredDocument> save({
    required String sourcePath,
    required String folderUri,
    List<String> path = const [],
    required String name,
    required String transferId,
    required bool replace,
  }) async {
    _requireGrant(folderUri);
    name = [...path, name].join('/');
    saves.add((folderUri: folderUri, name: name, replace: replace));
    final folder = folders[folderUri]!;
    if (folder.containsKey(name) && !replace) {
      throw PlatformException(
          code: 'SAF_ERROR',
          message: '$name already exists in the chosen folder.');
    }
    final bytes = File(sourcePath).readAsBytesSync();
    _inFlight.add(transferId);
    try {
      _progress.add(
          (transferId: transferId, copied: bytes.length ~/ 2, total: bytes.length));
      await saveGate?.future;
      if (_cancelled.remove(transferId)) {
        throw PlatformException(
            code: 'SAF_ERROR', message: 'The copy was cancelled.');
      }
      if (corruptOnSave && bytes.isNotEmpty) bytes[0] ^= 0xff;
      folder[name] = bytes;
      _progress.add(
          (transferId: transferId, copied: bytes.length, total: bytes.length));
      return StoredDocument(documentUri(folderUri, name), bytes.length);
    } finally {
      _inFlight.remove(transferId);
    }
  }

  @override
  Future<void> cancelSave(String transferId) async {
    if (!_inFlight.contains(transferId)) return;
    _cancelled.add(transferId);
    final gate = saveGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Stream<CopyProgress> get progress => _progress.stream;

  @override
  Future<String> sha256(String documentUri) async {
    final at = _locate(documentUri);
    if (at == null) {
      throw PlatformException(
          code: 'SAF_ERROR', message: 'Could not read the saved file.');
    }
    _requireGrant(at.$1);
    return sha256Hex(folders[at.$1]![at.$2]!);
  }

  @override
  Future<void> delete(String documentUri) async {
    final at = _locate(documentUri);
    if (at == null) return;
    folders[at.$1]!.remove(at.$2);
    deleted.add(documentUri);
  }
}

// ---------------------------------------------------------------------- api

/// RomDrop's API without a network, for screens.
class FakeRomDropApi extends RomDropApiService {
  FakeRomDropApi({super.baseUrl = 'https://romdrop.test:3002'})
      : super(token: testToken);

  RomDropCapabilities capabilitiesResult = RomDropCapabilities.fromJson(
      romDropExample('capabilities.response.json'));
  List<SystemPlatform> platformsResult = const [];
  final List<SystemAsset> catalogue = [];

  /// Thrown by the next requests while set.
  Object? error;

  /// While set, requests wait here.
  Completer<void>? hold;
  int capabilitiesCalls = 0;
  int platformCalls = 0;

  Future<void> _gate() async {
    await hold?.future;
    final failure = error;
    if (failure != null) throw failure;
  }

  @override
  Future<RomDropCapabilities> capabilities() async {
    capabilitiesCalls++;
    await _gate();
    return capabilitiesResult;
  }

  @override
  Future<List<SystemPlatform>> platforms() async {
    platformCalls++;
    await _gate();
    return platformsResult;
  }

  @override
  Future<List<SystemAsset>> assets(
      {required String platform, required SystemFileKind kind}) async {
    await _gate();
    return [
      for (final asset in catalogue)
        if (asset.platformId == platform && asset.kind == kind) asset
    ];
  }

  @override
  Future<SystemAsset> asset(String id) async {
    await _gate();
    return catalogue.firstWhere((asset) => asset.id == id,
        orElse: () => throw const RomDropException(RomDropErrorKind.notFound,
            'RomDrop no longer has this item. Refresh the list.'));
  }
}

// ---------------------------------------------------------------- transfers

/// Stands in for the network in screen tests. A transfer started through
/// [create] reports "downloading" and then waits until the test calls
/// [finish] or [fail]; finishing puts [contents] into the fake folder.
class FakeTransfers {
  FakeTransfers(this.storage);

  final FakeSystemFileStorage storage;

  /// File id → the bytes RomDrop would send.
  final Map<String, List<int>> contents = {};
  final List<SystemFileRequest> started = [];
  final Map<String, Completer<Object?>> _gates = {};

  SystemFileTransfer create({
    required SystemFileRequest request,
    required Directory stagingDir,
    required SystemFileStorage storage,
    RomDropApiService? client,
    void Function(SystemFileTaskStatus status, int bytes)? onStatus,
  }) =>
      _FakeTransfer(this, request, onStatus);

  bool isRunning(String fileId) =>
      _gates[fileId] != null && !_gates[fileId]!.isCompleted;

  void finish(String fileId) => _gates[fileId]!.complete(null);

  void fail(String fileId, Object error) => _gates[fileId]!.complete(error);
}

class _FakeTransfer extends SystemFileTransfer {
  _FakeTransfer(this._owner, SystemFileRequest request,
      void Function(SystemFileTaskStatus status, int bytes)? onStatus)
      : super(
          request: request,
          uri: Uri(),
          headers: const {},
          httpClient: HttpClient.new,
          storage: _owner.storage,
          stagingDir: Directory('unused-by-fake-transfers'),
          onStatus: onStatus,
        );

  final FakeTransfers _owner;

  @override
  void cancel() {
    final gate = _owner._gates[request.file.id];
    if (gate != null && !gate.isCompleted) {
      gate.complete(const SystemFileTransferCancelled());
    }
  }

  @override
  Future<void> discardPartial() async {}

  @override
  Future<StoredDocument> run() async {
    final file = request.file;
    _owner.started.add(request);
    final gate = _owner._gates[file.id] = Completer<Object?>();
    onStatus?.call(SystemFileTaskStatus.downloading, file.size ~/ 2);
    final failure = await gate.future;
    if (failure != null) throw failure;
    onStatus?.call(SystemFileTaskStatus.saving, file.size);
    final folder = _owner.storage.folders[request.folder.uri]!;
    folder[file.relativePath] = List.of(_owner.contents[file.id]!);
    return StoredDocument(
        _owner.storage.documentUri(request.folder.uri, file.relativePath),
        file.size);
  }
}

// ------------------------------------------------------------------- server

class RecordedRequest {
  RecordedRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;

  /// Lower-case header names.
  final Map<String, String> headers;
  final String body;
}

/// A local HTTP server the tests control. It only ever listens on loopback.
class FixtureServer {
  FixtureServer._(this._server);

  final HttpServer _server;
  final List<RecordedRequest> requests = [];
  final List<Completer<void>> _stalls = [];

  /// Answers every request; replace per test.
  Future<void> Function(HttpRequest request) handler =
      (request) => respondJson(request, 404, errorBody('not_found', 'Nothing here.'));

  String get url => 'http://127.0.0.1:${_server.port}';
  int get port => _server.port;

  static Future<FixtureServer> start({SecurityContext? tls}) async {
    final server = tls == null
        ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        : await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
    final fixture = FixtureServer._(server);
    server.listen((request) async {
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name] = values.join(', '));
      final body = request.method == 'GET' || request.method == 'HEAD'
          ? ''
          : await utf8.decodeStream(request);
      fixture.requests
          .add(RecordedRequest(request.method, request.uri, headers, body));
      try {
        await fixture.handler(request);
      } catch (_) {
        // The client went away mid-answer; the test asserts on its side.
      }
    });
    return fixture;
  }

  /// A future that never completes before the server closes: an answer that
  /// stops arriving.
  Future<void> stall() {
    final completer = Completer<void>();
    _stalls.add(completer);
    return completer.future;
  }

  Future<void> close() async {
    for (final stall in _stalls) {
      if (!stall.isCompleted) stall.complete();
    }
    await _server.close(force: true);
  }
}

Map<String, dynamic> errorBody(String code, String message) => {
      'error': {'code': code, 'message': message}
    };

Future<void> respondJson(HttpRequest request, int status, Object body) {
  final response = request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..headers.set('Cache-Control', 'no-store')
    ..write(jsonEncode(body));
  return response.close();
}

/// Answers a download the way RomDrop does: a device token is required, the
/// ETag is the content hash, and one range with If-Range is honoured.
///
/// [cutAfter] sends only that many body bytes and then drops the connection.
Future<void> serveSystemFile(
  HttpRequest request,
  List<int> bytes, {
  String token = testToken,
  int? cutAfter,
}) async {
  if (request.headers.value('authorization') != 'Bearer $token') {
    return respondJson(request, 401,
        errorBody('unauthorized', 'Sign in or send a device token.'));
  }
  final response = request.response;
  final etag = '"sha256-${sha256Hex(bytes)}"';
  response.headers
    ..set('ETag', etag)
    ..set('Accept-Ranges', 'bytes')
    ..set('Cache-Control', 'no-store')
    ..contentType = ContentType.binary;
  var start = 0;
  final range = request.headers.value('range');
  final ifRange = request.headers.value('if-range');
  final match =
      range == null ? null : RegExp(r'^bytes=(\d+)-$').firstMatch(range);
  if (match != null && (ifRange == null || ifRange == etag)) {
    start = int.parse(match.group(1)!);
    if (start >= bytes.length) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set('Content-Range', 'bytes */${bytes.length}');
      return response.close();
    }
    response
      ..statusCode = HttpStatus.partialContent
      ..headers.set(
          'Content-Range', 'bytes $start-${bytes.length - 1}/${bytes.length}');
  }
  final body = bytes.sublist(start);
  response.contentLength = body.length;
  if (cutAfter != null && cutAfter < body.length) {
    // The headers promise the whole body; the socket then delivers part of
    // it and goes away.
    final socket = await response.detachSocket();
    socket.add(body.sublist(0, cutAfter));
    await socket.flush();
    // Give the client time to take what was sent before the line drops.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    socket.destroy();
    return;
  }
  response.add(body);
  await response.close();
}
