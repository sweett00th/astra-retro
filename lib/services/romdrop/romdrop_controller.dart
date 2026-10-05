import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/romdrop_models.dart';
import '../download_foreground_service.dart';
import 'romdrop_api_service.dart';
import 'romdrop_connection.dart';
import 'system_file_download_manager.dart';
import 'system_file_storage.dart';

/// Whether a system file is on this device. Being saved here says nothing
/// about the emulator having imported it.
enum LocalFileState {
  notSaved,
  saved,

  /// It was saved, but the file is no longer where it was put.
  gone,
}

enum DestinationState {
  /// The folder grant was revoked or the folder is gone.
  noAccess,
  free,

  /// A file of that name with the same contents is already there.
  sameFile,

  /// A file of that name with other contents is there.
  differentFile,
}

/// The RomDrop connection and everything hanging off it: destinations, the
/// record of saved files and the system-file transfer queue.
class RomDropController extends ChangeNotifier {
  RomDropController({
    required SharedPreferences prefs,
    required this.storage,
    RomDropConnectionStore? connectionStore,
    Future<Directory> Function()? stagingDirectory,
    RomDropApiService Function(RomDropConnection connection, String token)?
        apiFactory,
    SystemFileTransferFactory? transferFactory,
    bool keepAliveWhileBusy = true,
  })  : connectionStore = connectionStore ?? RomDropConnectionStore(prefs),
        destinations = SystemFileDestinations(prefs),
        saved = SavedSystemFiles(prefs),
        _apiFactory = apiFactory ??
            ((connection, token) => RomDropApiService(
                  baseUrl: connection.baseUrl,
                  token: token,
                  pinnedFingerprint: connection.certificateFingerprint,
                )) {
    downloads = SystemFileDownloadManager(
      storage: storage,
      saved: saved,
      stagingDirectory: stagingDirectory ?? _defaultStaging,
      api: () => _api,
      prefs: prefs,
      transferFactory: transferFactory,
      onBusyChanged: keepAliveWhileBusy
          ? (busy) => busy
              ? DownloadForegroundService.hold(_holdName)
              : DownloadForegroundService.release(_holdName)
          : null,
    );
  }

  static const _holdName = 'system_files';

  final SystemFileStorage storage;
  final RomDropConnectionStore connectionStore;
  final SystemFileDestinations destinations;
  final SavedSystemFiles saved;
  late final SystemFileDownloadManager downloads;
  final RomDropApiService Function(RomDropConnection, String) _apiFactory;

  RomDropConnection? _connection;
  RomDropApiService? _api;

  RomDropConnection? get connection => _connection;
  RomDropApiService? get api => _api;
  bool get configured => _api != null;

  static Future<Directory> _defaultStaging() async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'system_files'));

  /// Loads the stored connection and any interrupted transfers.
  Future<void> load() async {
    final connection = connectionStore.read();
    final token = connection == null ? null : await connectionStore.readToken();
    if (connection != null && token != null && token.isNotEmpty) {
      _connection = connection;
      _api = _apiFactory(connection, token);
    }
    await downloads.restore();
    notifyListeners();
  }

  Future<void> connect(RomDropConnection connection, String token) async {
    await connectionStore.save(connection, token);
    _connection = connection;
    _api = _apiFactory(connection, token);
    notifyListeners();
  }

  /// Forgets the server on this device. The credential remains valid on the
  /// server until it is revoked there.
  Future<void> disconnect() async {
    await connectionStore.clear();
    _connection = null;
    _api = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ local state

  Future<LocalFileState> localState(SystemFileInfo file) async {
    final record = saved[file.id];
    if (record == null) return LocalFileState.notSaved;
    try {
      final document = await storage.find(record.folderUri, record.filename,
          path: record.directories);
      return document != null &&
              !document.isFolder &&
              document.size == record.size
          ? LocalFileState.saved
          : LocalFileState.gone;
    } catch (e) {
      debugPrint('RomDrop: could not check ${record.filename}: $e');
      return LocalFileState.gone;
    }
  }

  Future<DestinationState> checkDestination(
      SystemFileInfo file, SystemFileFolder folder) async {
    if (!await storage.canWrite(folder.uri)) return DestinationState.noAccess;
    final existing =
        await storage.find(folder.uri, file.filename, path: file.directories);
    if (existing == null) return DestinationState.free;
    if (!existing.isFolder &&
        existing.size == file.size &&
        await storage.sha256(existing.uri) == file.sha256) {
      return DestinationState.sameFile;
    }
    return DestinationState.differentFile;
  }

  /// Records a file that is already in the folder with identical contents,
  /// so it is not downloaded again.
  Future<void> adoptExisting({
    required SystemAsset asset,
    required SystemFileInfo file,
    required SystemFileFolder folder,
  }) async {
    final existing =
        await storage.find(folder.uri, file.filename, path: file.directories);
    if (existing == null || existing.isFolder) return;
    await saved.put(SavedSystemFile(
      fileId: file.id,
      assetId: asset.id,
      versionId: file.versionId,
      platformId: asset.platformId,
      filename: file.filename,
      relativePath: file.relativePath,
      sha256: file.sha256,
      size: file.size,
      folderUri: folder.uri,
      folderName: folder.name,
      documentUri: existing.uri,
      savedAt: DateTime.now().toIso8601String(),
    ));
  }

  Future<void> setImportConfirmed(String fileId, bool value) async {
    final record = saved[fileId];
    if (record != null) await saved.put(record.withImportConfirmed(value));
  }

  @override
  void dispose() {
    downloads.dispose();
    destinations.dispose();
    saved.dispose();
    super.dispose();
  }
}
