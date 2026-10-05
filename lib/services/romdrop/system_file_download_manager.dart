import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/romdrop_models.dart';
import '../../utils/friendly_error.dart';
import '../disk_space_service.dart';
import 'romdrop_api_service.dart';
import 'system_file_storage.dart';

/// One system file to fetch from RomDrop and save into a user-chosen folder.
/// This is its own task type: it is not a game download and never enters the
/// game queue, the library or extraction.
class SystemFileRequest {
  final SystemFileInfo file;
  final String assetId;
  final String assetName;
  final String platformId;
  final String versionLabel;
  final SystemFileFolder folder;

  /// The user agreed to replace a different file of the same name.
  final bool replace;

  const SystemFileRequest({
    required this.file,
    required this.assetId,
    required this.assetName,
    required this.platformId,
    required this.versionLabel,
    required this.folder,
    this.replace = false,
  });

  Map<String, dynamic> toJson() => {
        'file': {
          'id': file.id,
          'version_id': file.versionId,
          'filename': file.filename,
          'relative_path': file.relativePath,
          'size': file.size,
          'sha256': file.sha256,
          'etag': file.etag,
          'download_path': file.downloadPath,
        },
        'assetId': assetId,
        'assetName': assetName,
        'platformId': platformId,
        'versionLabel': versionLabel,
        'folder': folder.toJson(),
        'replace': replace,
      };

  static SystemFileRequest? fromJson(Map<String, dynamic> json) {
    try {
      final folder = SystemFileFolder.fromJson(json['folder']);
      if (folder == null) return null;
      return SystemFileRequest(
        file: SystemFileInfo.fromJson(
            Map<String, dynamic>.from(json['file'] as Map)),
        assetId: json['assetId'] as String,
        assetName: json['assetName'] as String,
        platformId: json['platformId'] as String,
        versionLabel: json['versionLabel'] as String? ?? '',
        folder: folder,
        replace: json['replace'] == true,
      );
    } catch (e) {
      debugPrint('SystemFileRequest: stored task is unreadable: $e');
      return null;
    }
  }
}

enum SystemFileTaskStatus {
  queued,
  downloading,
  verifying,
  saving,
  completed,
  failed,
  cancelled;

  bool get active =>
      this == downloading || this == verifying || this == saving;
  bool get finished => this == completed || this == failed || this == cancelled;
}

class SystemFileTask {
  SystemFileTask(this.request);

  final SystemFileRequest request;
  SystemFileTaskStatus status = SystemFileTaskStatus.queued;
  int receivedBytes = 0;
  int savedBytes = 0;
  String? error;
  RomDropErrorKind? errorKind;
  int attempts = 0;

  String get id => request.file.id;
  int get totalBytes => request.file.size;

  double get progress {
    if (totalBytes <= 0) return 0;
    final done =
        status == SystemFileTaskStatus.saving ? savedBytes : receivedBytes;
    return (done / totalBytes).clamp(0.0, 1.0);
  }

  /// Each stage is named for what it is: receiving from RomDrop, checking,
  /// then writing into the chosen folder.
  String get statusText => switch (status) {
        SystemFileTaskStatus.queued =>
          attempts > 0 ? 'Waiting to retry' : 'Waiting',
        SystemFileTaskStatus.downloading =>
          'Downloading from RomDrop ${(progress * 100).toStringAsFixed(0)}%',
        SystemFileTaskStatus.verifying => 'Checking the download',
        SystemFileTaskStatus.saving =>
          'Saving to ${request.folder.name} ${(progress * 100).toStringAsFixed(0)}%',
        SystemFileTaskStatus.completed => 'Saved to ${request.folder.name}',
        SystemFileTaskStatus.failed => error ?? 'Failed',
        SystemFileTaskStatus.cancelled => 'Cancelled',
      };
}

class SystemFileTransferException extends UserFacingException {
  const SystemFileTransferException(super.message,
      {this.retryable = false, this.keepPartial = true});

  /// Worth trying again unattended (a network hiccup).
  final bool retryable;

  /// The partial download is still good to resume from.
  final bool keepPartial;
}

/// The user cancelled the transfer; not a failure.
class SystemFileTransferCancelled implements Exception {
  const SystemFileTransferCancelled();
}

Future<String> sha256OfFile(String path) => Isolate.run(
    () async => (await sha256.bind(File(path).openRead()).first).toString());

/// Downloads one file with resume, verifies it, then hands it to the folder.
///
/// The bytes land in app-private staging first. Document folders are not
/// seekable, so a transfer is only resumed in staging; the folder receives
/// the file in one pass after its length and SHA-256 are confirmed.
class SystemFileTransfer {
  SystemFileTransfer({
    required this.request,
    required this.uri,
    required this.headers,
    required this.httpClient,
    required this.storage,
    required this.stagingDir,
    this.onStatus,
    this.stallTimeout = const Duration(seconds: 60),
  });

  final SystemFileRequest request;
  final Uri uri;
  final Map<String, String> headers;
  final HttpClient Function() httpClient;
  final SystemFileStorage storage;
  final Directory stagingDir;
  final void Function(SystemFileTaskStatus status, int bytes)? onStatus;
  final Duration stallTimeout;

  bool _cancelled = false;
  bool _saving = false;
  HttpClient? _client;
  StreamSubscription<CopyProgress>? _copySub;

  SystemFileInfo get _file => request.file;
  File get stagingFile => File(p.join(stagingDir.path, '${_file.id}.part'));
  File get _metaFile => File(p.join(stagingDir.path, '${_file.id}.json'));
  String get _transferId => _file.id;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
    if (_saving) {
      storage.cancelSave(_transferId).catchError((Object e) {
        debugPrint('SystemFileTransfer: could not stop the copy: $e');
      });
    }
  }

  void _check() {
    if (_cancelled) throw const SystemFileTransferCancelled();
  }

  Future<void> discardPartial() async {
    for (final file in [stagingFile, _metaFile]) {
      await _remove(file);
    }
  }

  Future<void> _remove(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('SystemFileTransfer: could not remove ${file.path}: $e');
    }
  }

  Future<StoredDocument> run() async {
    if (!_file.available) {
      throw const SystemFileTransferException(
          'This file is not available on the server right now.');
    }
    if (_file.extract) {
      throw const SystemFileTransferException(
          'RomDrop asks for this file to be unpacked, which this version of the app does not do.');
    }
    if (!await storage.canWrite(request.folder.uri)) {
      throw SystemFileTransferException(
          'R-Shop no longer has access to "${request.folder.name}". Choose the folder again under Destinations.');
    }
    final existing = await storage.find(request.folder.uri, _file.filename,
        path: _file.directories);
    if (existing != null && !request.replace) {
      throw SystemFileTransferException(
          '"${_file.relativePath}" already exists in ${request.folder.name}.');
    }
    await stagingDir.create(recursive: true);
    _check();
    await _download();
    _check();

    onStatus?.call(SystemFileTaskStatus.verifying, _file.size);
    final length = await stagingFile.length();
    if (length != _file.size) {
      throw SystemFileTransferException(
          'The download is incomplete ($length of ${_file.size} bytes).',
          retryable: true);
    }
    if (await sha256OfFile(stagingFile.path) != _file.sha256) {
      await discardPartial();
      throw const SystemFileTransferException(
          'The downloaded file does not match RomDrop\'s checksum. It was discarded; try again.',
          keepPartial: false);
    }
    _check();

    onStatus?.call(SystemFileTaskStatus.saving, 0);
    _copySub = storage.progress
        .where((event) => event.transferId == _transferId)
        .listen((event) =>
            onStatus?.call(SystemFileTaskStatus.saving, event.copied));
    late final StoredDocument saved;
    _saving = true;
    try {
      saved = await storage.save(
        sourcePath: stagingFile.path,
        folderUri: request.folder.uri,
        path: _file.directories,
        name: _file.filename,
        transferId: _transferId,
        replace: request.replace,
      );
    } catch (e) {
      _check(); // a copy that was cancelled fails on purpose
      rethrow;
    } finally {
      _saving = false;
      await _copySub?.cancel();
    }
    // Trust nothing about the copy until the folder's own bytes check out.
    if (saved.size != _file.size ||
        await storage.sha256(saved.uri) != _file.sha256) {
      try {
        await storage.delete(saved.uri);
      } catch (e) {
        debugPrint('SystemFileTransfer: could not remove bad copy: $e');
      }
      throw const SystemFileTransferException(
          'The file did not arrive intact in the folder and was removed. Try again.');
    }
    await discardPartial();
    return saved;
  }

  /// Bytes of a previous attempt that still belong to this exact file.
  Future<int> _resumeOffset() async {
    try {
      if (!await stagingFile.exists() || !await _metaFile.exists()) {
        await discardPartial();
        return 0;
      }
      final meta = jsonDecode(await _metaFile.readAsString()) as Map;
      final length = await stagingFile.length();
      if (meta['etag'] != _file.etag ||
          meta['size'] != _file.size ||
          length > _file.size) {
        await discardPartial();
        return 0;
      }
      return length;
    } catch (e) {
      await discardPartial();
      return 0;
    }
  }

  Future<void> _download() async {
    var offset = await _resumeOffset();
    if (_file.size == 0) {
      await stagingFile.writeAsBytes(const []);
      return;
    }
    if (offset == _file.size) return; // finished earlier; verification follows
    await _ensureFreeSpace(_file.size - offset);
    await _metaFile
        .writeAsString(jsonEncode({'etag': _file.etag, 'size': _file.size}));

    for (var attempt = 0; attempt < 2; attempt++) {
      _check();
      final client = _client = httpClient();
      try {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (offset > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
          // Resume only the same bytes; anything else restarts cleanly.
          request.headers.set(HttpHeaders.ifRangeHeader, _file.etag);
        }
        final response =
            await request.close().timeout(const Duration(seconds: 30));
        final etag = response.headers.value(HttpHeaders.etagHeader);
        if (response.statusCode == HttpStatus.ok) {
          if (etag != null && etag != _file.etag ||
              response.contentLength >= 0 &&
                  response.contentLength != _file.size) {
            await response.drain<void>();
            await discardPartial();
            throw const SystemFileTransferException(
                'This file changed on the server. Refresh and start again.',
                keepPartial: false);
          }
          offset = 0; // the server sent everything: never append to old bytes
        } else if (response.statusCode == HttpStatus.partialContent) {
          final expected = 'bytes $offset-${_file.size - 1}/${_file.size}';
          final range = response.headers
              .value(HttpHeaders.contentRangeHeader)
              ?.replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (range != expected || etag != null && etag != _file.etag) {
            await response.drain<void>();
            await _remove(stagingFile);
            offset = 0;
            continue; // not the range asked for: start over without one
          }
        } else if (response.statusCode ==
            HttpStatus.requestedRangeNotSatisfiable) {
          await response.drain<void>();
          await _remove(stagingFile);
          offset = 0;
          continue;
        } else {
          throw await _httpFailure(response);
        }
        await _receive(response, offset);
        return;
      } on SystemFileTransferCancelled {
        rethrow;
      } on UserFacingException {
        rethrow;
      } on HandshakeException {
        throw const RomDropException(RomDropErrorKind.certificate,
            'RomDrop presented a certificate this device has not accepted. Open Settings > RomDrop and check the connection.');
      } on TimeoutException {
        _check();
        throw const SystemFileTransferException(
            'RomDrop stopped sending data. The download will resume.',
            retryable: true);
      } on IOException catch (e) {
        _check();
        if (e is FileSystemException) {
          throw SystemFileTransferException(
              'Could not write the download on this device: ${e.osError?.message ?? e.message}');
        }
        throw const SystemFileTransferException(
            'The connection to RomDrop was lost. The download will resume.',
            retryable: true);
      } finally {
        client.close(force: true);
        _client = null;
      }
    }
    throw const SystemFileTransferException(
        'RomDrop would not continue this download. Try again later.');
  }

  Future<void> _receive(HttpClientResponse response, int offset) async {
    final output = await stagingFile
        .open(mode: offset > 0 ? FileMode.append : FileMode.write);
    var received = offset;
    var lastReport = DateTime.now();
    onStatus?.call(SystemFileTaskStatus.downloading, received);
    try {
      await for (final chunk in response.timeout(stallTimeout)) {
        _check();
        await output.writeFrom(chunk);
        received += chunk.length;
        if (received > _file.size) {
          throw const SystemFileTransferException(
              'RomDrop sent more data than the file should have.',
              keepPartial: false);
        }
        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds >= 250) {
          lastReport = now;
          onStatus?.call(SystemFileTaskStatus.downloading, received);
        }
      }
      await output.flush();
    } finally {
      await output.close();
    }
    onStatus?.call(SystemFileTaskStatus.downloading, received);
  }

  Future<Exception> _httpFailure(HttpClientResponse response) async {
    String? code;
    String? message;
    try {
      final body = await utf8.decoder
          .bind(response.take(64))
          .join()
          .timeout(const Duration(seconds: 10));
      final error = (jsonDecode(body) as Map)['error'] as Map;
      code = error['code'] as String?;
      message = error['message'] as String?;
    } catch (_) {
      // Not a RomDrop error body; the status code decides.
    }
    return RomDropApiService.errorFor(response.statusCode,
        code: code, message: message);
  }

  Future<void> _ensureFreeSpace(int needed) async {
    final info = await DiskSpaceService.getFreeSpace(stagingDir.path);
    const margin = 64 * 1024 * 1024;
    if (info != null && info.freeBytes < needed + margin) {
      throw SystemFileTransferException(
          'Not enough free space on this device: ${formatSystemFileSize(needed)} needed, ${info.freeSpaceSize} free.');
    }
  }
}

/// Builds the transfer for one request. [client] is null when RomDrop is not
/// connected, which is only the case for clearing a partial download.
typedef SystemFileTransferFactory = SystemFileTransfer Function({
  required SystemFileRequest request,
  required Directory stagingDir,
  required SystemFileStorage storage,
  RomDropApiService? client,
  void Function(SystemFileTaskStatus status, int bytes)? onStatus,
});

SystemFileTransfer _httpTransfer({
  required SystemFileRequest request,
  required Directory stagingDir,
  required SystemFileStorage storage,
  RomDropApiService? client,
  void Function(SystemFileTaskStatus status, int bytes)? onStatus,
}) =>
    SystemFileTransfer(
      request: request,
      uri: client?.downloadUri(request.file) ?? Uri(),
      headers: client?.authHeaders ?? const {},
      httpClient: () => RomDropApiService.httpClient(client?.pinnedFingerprint),
      storage: storage,
      stagingDir: stagingDir,
      onStatus: onStatus,
    );

/// Queue of system-file transfers, one at a time. Separate from the game
/// download queue; it only shares the keep-alive notification.
class SystemFileDownloadManager extends ChangeNotifier {
  SystemFileDownloadManager({
    required this.storage,
    required this.saved,
    required this.stagingDirectory,
    required this.api,
    this.prefs,
    this.onBusyChanged,
    SystemFileTransferFactory? transferFactory,
    this.retryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 45)
    ],
  }) : transferFactory = transferFactory ?? _httpTransfer;

  static const _tasksKey = 'system_file_tasks';

  final SystemFileStorage storage;
  final SavedSystemFiles saved;
  final Future<Directory> Function() stagingDirectory;

  /// The current connection's client, or null when disconnected.
  final RomDropApiService? Function() api;
  final SharedPreferences? prefs;
  final void Function(bool busy)? onBusyChanged;
  final SystemFileTransferFactory transferFactory;
  final List<Duration> retryDelays;

  final List<SystemFileTask> _tasks = [];
  final Map<String, Timer> _retryTimers = {};
  SystemFileTransfer? _running;
  bool _pumping = false;
  bool _disposed = false;
  bool _busy = false;

  List<SystemFileTask> get tasks => List.unmodifiable(_tasks);

  SystemFileTask? task(String fileId) {
    for (final task in _tasks) {
      if (task.id == fileId) return task;
    }
    return null;
  }

  bool get busy => _tasks.any((t) =>
      t.status.active ||
      t.status == SystemFileTaskStatus.queued ||
      _retryTimers.containsKey(t.id));

  void _changed() {
    if (_disposed) return;
    final nowBusy = busy;
    if (nowBusy != _busy) {
      _busy = nowBusy;
      onBusyChanged?.call(nowBusy);
    }
    notifyListeners();
  }

  /// Starts (or restarts) a download the user asked for.
  void enqueue(SystemFileRequest request) {
    final existing = task(request.file.id);
    if (existing != null && !existing.status.finished) return;
    _retryTimers.remove(request.file.id)?.cancel();
    _tasks.removeWhere((t) => t.id == request.file.id);
    _tasks.insert(0, SystemFileTask(request));
    _persist();
    _changed();
    _pump();
  }

  /// Continues a failed or interrupted download from where it stopped.
  void retry(String fileId) {
    final current = task(fileId);
    if (current == null || !current.status.finished) return;
    _retryTimers.remove(fileId)?.cancel();
    current
      ..status = SystemFileTaskStatus.queued
      ..error = null
      ..errorKind = null
      ..attempts = 0;
    _persist();
    _changed();
    _pump();
  }

  Future<void> cancel(String fileId) async {
    final current = task(fileId);
    if (current == null || current.status == SystemFileTaskStatus.completed) {
      return;
    }
    _retryTimers.remove(fileId)?.cancel();
    final running = _running;
    if (running != null && running.request.file.id == fileId) {
      running.cancel(); // the worker marks it cancelled and cleans up
      return;
    }
    current.status = SystemFileTaskStatus.cancelled;
    await _transfer(current.request, await stagingDirectory()).discardPartial();
    _persist();
    _changed();
  }

  void dismiss(String fileId) {
    final current = task(fileId);
    if (current == null || !current.status.finished) return;
    _retryTimers.remove(fileId)?.cancel();
    _tasks.remove(current);
    _persist();
    _changed();
  }

  SystemFileTransfer _transfer(SystemFileRequest request, Directory staging,
      {RomDropApiService? client, SystemFileTask? task}) {
    return transferFactory(
      request: request,
      client: client,
      storage: storage,
      stagingDir: staging,
      onStatus: task == null
          ? null
          : (status, bytes) {
              task.status = status;
              if (status == SystemFileTaskStatus.saving) {
                task.savedBytes = bytes;
              } else {
                task.receivedBytes = bytes;
              }
              _changed();
            },
    );
  }

  Future<void> _pump() async {
    if (_pumping || _disposed) return;
    _pumping = true;
    try {
      while (!_disposed) {
        final next = _tasks.reversed
            .where((t) => t.status == SystemFileTaskStatus.queued)
            .firstOrNull;
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(SystemFileTask task) async {
    final client = api();
    if (client == null) {
      task
        ..status = SystemFileTaskStatus.failed
        ..errorKind = RomDropErrorKind.notConfigured
        ..error = 'Connect to RomDrop first (Settings > RomDrop).';
      _persist();
      _changed();
      return;
    }
    final staging = await stagingDirectory();
    final transfer =
        _running = _transfer(task.request, staging, client: client, task: task);
    task
      ..status = SystemFileTaskStatus.downloading
      ..attempts += 1
      ..error = null
      ..errorKind = null;
    _changed();
    try {
      final document = await transfer.run();
      final file = task.request.file;
      await saved.put(SavedSystemFile(
        fileId: file.id,
        assetId: task.request.assetId,
        versionId: file.versionId,
        platformId: task.request.platformId,
        filename: file.filename,
        relativePath: file.relativePath,
        sha256: file.sha256,
        size: file.size,
        folderUri: task.request.folder.uri,
        folderName: task.request.folder.name,
        documentUri: document.uri,
        savedAt: DateTime.now().toIso8601String(),
      ));
      task
        ..status = SystemFileTaskStatus.completed
        ..receivedBytes = file.size
        ..savedBytes = file.size;
    } on SystemFileTransferCancelled {
      await transfer.discardPartial();
      task.status = SystemFileTaskStatus.cancelled;
    } catch (e) {
      final retryable = e is SystemFileTransferException && e.retryable ||
          e is RomDropException && e.retryable;
      if (e is SystemFileTransferException && !e.keepPartial) {
        await transfer.discardPartial();
      }
      task
        ..error = getUserFriendlyError(e, returnRawOnNoMatch: true)
        ..errorKind = e is RomDropException ? e.kind : null;
      if (retryable && task.attempts <= retryDelays.length && !_disposed) {
        // Left queued-in-waiting; the partial file stays for the resume.
        task.status = SystemFileTaskStatus.failed;
        _retryTimers[task.id] = Timer(retryDelays[task.attempts - 1], () {
          _retryTimers.remove(task.id);
          if (_disposed || task.status != SystemFileTaskStatus.failed) return;
          task.status = SystemFileTaskStatus.queued;
          _changed();
          _pump();
        });
      } else {
        task.status = SystemFileTaskStatus.failed;
      }
      debugPrint('SystemFileDownload: ${task.request.file.filename}: ${task.error}');
    } finally {
      _running = null;
      _persist();
      _changed();
    }
  }

  // ------------------------------------------------------------ persistence

  /// Unfinished work is remembered so a restart can offer to continue it.
  void _persist() {
    final pending = [
      for (final task in _tasks)
        if (task.status != SystemFileTaskStatus.completed &&
            task.status != SystemFileTaskStatus.cancelled)
          task.request.toJson()
    ];
    final store = prefs;
    if (store == null) return;
    if (pending.isEmpty) {
      store.remove(_tasksKey);
    } else {
      store.setString(_tasksKey, jsonEncode(pending));
    }
  }

  /// Brings back downloads that were cut off by the app closing. They wait
  /// for the user to continue them; nothing restarts by itself.
  Future<void> restore() async {
    final raw = prefs?.getString(_tasksKey);
    if (raw != null) {
      try {
        for (final item in jsonDecode(raw) as List) {
          final request =
              SystemFileRequest.fromJson(Map<String, dynamic>.from(item as Map));
          if (request == null || task(request.file.id) != null) continue;
          _tasks.add(SystemFileTask(request)
            ..status = SystemFileTaskStatus.failed
            ..error = 'Interrupted. Continue to pick up where it stopped.');
        }
      } catch (e) {
        debugPrint('SystemFileDownload: stored tasks are unreadable: $e');
        prefs?.remove(_tasksKey);
      }
    }
    await _cleanStaging();
    _changed();
  }

  /// Partial files nobody is going to resume do not stay forever.
  Future<void> _cleanStaging() async {
    try {
      final dir = await stagingDirectory();
      if (!await dir.exists()) return;
      final wanted = {for (final task in _tasks) task.id};
      final now = DateTime.now();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final id = p.basenameWithoutExtension(entity.path);
        final age = now.difference((await entity.stat()).modified);
        if (!wanted.contains(id) || age > const Duration(days: 14)) {
          await entity.delete();
        }
      }
    } catch (e) {
      debugPrint('SystemFileDownload: staging clean-up failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _running?.cancel();
    if (_busy) onBusyChanged?.call(false);
    super.dispose();
  }
}
