import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A folder the user granted through Android's folder picker.
class SystemFileFolder {
  final String uri;
  final String name;
  const SystemFileFolder(this.uri, this.name);

  Map<String, dynamic> toJson() => {'uri': uri, 'name': name};

  static SystemFileFolder? fromJson(Object? json) {
    if (json is! Map) return null;
    final uri = json['uri'];
    final name = json['name'];
    if (uri is! String || uri.isEmpty) return null;
    return SystemFileFolder(uri, name is String ? name : uri);
  }
}

class StoredDocument {
  final String uri;
  final int size;

  /// A folder is where the file was looked for.
  final bool isFolder;
  const StoredDocument(this.uri, this.size, {this.isFolder = false});
}

typedef CopyProgress = ({String transferId, int copied, int total});

/// Writing into user-granted folders. System files go where an emulator can
/// read them, which is outside this app's own storage, so every write goes
/// through Android's Storage Access Framework with a persisted grant. Nothing
/// here assumes access to another app's Android/data folder.
abstract class SystemFileStorage {
  /// Opens the folder picker. Null when the user cancels.
  Future<SystemFileFolder?> pickFolder({String? initialUri});

  /// Whether the grant for [folderUri] still stands and the folder exists.
  Future<bool> canWrite(String folderUri);

  /// Gives up the grant for a folder no longer used.
  Future<void> release(String folderUri);

  /// Looks for [name] in the folder, below the sub-folders in [path].
  Future<StoredDocument?> find(String folderUri, String name,
      {List<String> path = const []});

  /// Copies a finished local file into the folder under exactly [name],
  /// below the sub-folders in [path] (created as needed). The bytes are
  /// written under a temporary name first, so [name] never refers to a
  /// half-written file.
  Future<StoredDocument> save({
    required String sourcePath,
    required String folderUri,
    List<String> path = const [],
    required String name,
    required String transferId,
    required bool replace,
  });

  /// Stops a [save] that is still copying; that call then fails and leaves
  /// nothing behind. Does nothing when no such copy is running.
  Future<void> cancelSave(String transferId);

  Stream<CopyProgress> get progress;

  Future<String> sha256(String documentUri);

  Future<void> delete(String documentUri);
}

class SafSystemFileStorage implements SystemFileStorage {
  static const _channel = MethodChannel('com.retro.rshop/saf');
  static const _events = EventChannel('com.retro.rshop/saf_progress');

  Stream<CopyProgress>? _progress;

  @override
  Future<SystemFileFolder?> pickFolder({String? initialUri}) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
        'pickTree', {'initialUri': initialUri});
    return SystemFileFolder.fromJson(result);
  }

  @override
  Future<bool> canWrite(String folderUri) async =>
      await _channel.invokeMethod<bool>('canWrite', {'treeUri': folderUri}) ??
      false;

  @override
  Future<void> release(String folderUri) =>
      _channel.invokeMethod<void>('release', {'treeUri': folderUri});

  @override
  Future<StoredDocument?> find(String folderUri, String name,
      {List<String> path = const []}) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
        'findDocument', {'treeUri': folderUri, 'path': path, 'name': name});
    if (result == null) return null;
    return StoredDocument(
        result['uri'] as String, (result['size'] as num?)?.toInt() ?? 0,
        isFolder: result['folder'] == true);
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
    final result =
        await _channel.invokeMapMethod<String, dynamic>('copyFile', {
      'sourcePath': sourcePath,
      'treeUri': folderUri,
      'path': path,
      'name': name,
      'transferId': transferId,
      'replace': replace,
    });
    return StoredDocument(
        result!['uri'] as String, (result['size'] as num).toInt());
  }

  @override
  Future<void> cancelSave(String transferId) =>
      _channel.invokeMethod<void>('cancelCopy', {'transferId': transferId});

  @override
  Stream<CopyProgress> get progress =>
      _progress ??= _events.receiveBroadcastStream().map((event) {
        final map = event as Map;
        return (
          transferId: map['transferId'] as String,
          copied: (map['copied'] as num).toInt(),
          total: (map['total'] as num).toInt(),
        );
      });

  @override
  Future<String> sha256(String documentUri) async =>
      (await _channel.invokeMethod<String>('sha256', {'uri': documentUri}))!;

  @override
  Future<void> delete(String documentUri) =>
      _channel.invokeMethod<void>('deleteDocument', {'uri': documentUri});
}

/// Where system files are saved: one default folder, with an optional
/// override per platform.
class SystemFileDestinations extends ChangeNotifier {
  SystemFileDestinations(this._prefs) {
    final raw = _prefs.getString(_key);
    if (raw == null) return;
    try {
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      _defaultFolder = SystemFileFolder.fromJson(json['default']);
      final platforms = json['platforms'];
      if (platforms is Map) {
        for (final entry in platforms.entries) {
          final folder = SystemFileFolder.fromJson(entry.value);
          if (folder != null) _platforms[entry.key as String] = folder;
        }
      }
    } catch (e) {
      debugPrint('SystemFileDestinations: stored value is unreadable: $e');
    }
  }

  static const _key = 'system_file_destinations';
  final SharedPreferences _prefs;
  SystemFileFolder? _defaultFolder;
  final Map<String, SystemFileFolder> _platforms = {};

  SystemFileFolder? get defaultFolder => _defaultFolder;
  SystemFileFolder? platformOverride(String platformId) =>
      _platforms[platformId];

  /// The folder a platform's files go to, or null when none is chosen yet.
  SystemFileFolder? resolve(String platformId) =>
      _platforms[platformId] ?? _defaultFolder;

  /// Folder grants still referenced by a setting.
  Set<String> get uris =>
      {if (_defaultFolder != null) _defaultFolder!.uri, for (final f in _platforms.values) f.uri};

  Future<void> setDefault(SystemFileFolder? folder) async {
    _defaultFolder = folder;
    await _save();
  }

  Future<void> setPlatform(String platformId, SystemFileFolder? folder) async {
    if (folder == null) {
      _platforms.remove(platformId);
    } else {
      _platforms[platformId] = folder;
    }
    await _save();
  }

  Future<void> _save() async {
    await _prefs.setString(
        _key,
        jsonEncode({
          if (_defaultFolder != null) 'default': _defaultFolder!.toJson(),
          'platforms': {
            for (final entry in _platforms.entries)
              entry.key: entry.value.toJson()
          },
        }));
    notifyListeners();
  }
}

/// A system file this device saved, and where. "Saved on this device" is all
/// it claims: whether the emulator has imported the file is a separate fact
/// only the user can confirm ([importConfirmed]).
class SavedSystemFile {
  final String fileId;
  final String assetId;
  final String versionId;
  final String platformId;
  final String filename;

  /// Where the file sits below [folderUri]; the file name when it is
  /// directly in it.
  final String relativePath;
  final String sha256;
  final int size;
  final String folderUri;
  final String folderName;
  final String documentUri;
  final String savedAt;
  final bool importConfirmed;

  const SavedSystemFile({
    required this.fileId,
    required this.assetId,
    required this.versionId,
    required this.platformId,
    required this.filename,
    required this.relativePath,
    required this.sha256,
    required this.size,
    required this.folderUri,
    required this.folderName,
    required this.documentUri,
    required this.savedAt,
    this.importConfirmed = false,
  });

  List<String> get directories => relativePath.split('/')..removeLast();

  SavedSystemFile withImportConfirmed(bool value) => SavedSystemFile(
        fileId: fileId,
        assetId: assetId,
        versionId: versionId,
        platformId: platformId,
        filename: filename,
        relativePath: relativePath,
        sha256: sha256,
        size: size,
        folderUri: folderUri,
        folderName: folderName,
        documentUri: documentUri,
        savedAt: savedAt,
        importConfirmed: value,
      );

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'assetId': assetId,
        'versionId': versionId,
        'platformId': platformId,
        'filename': filename,
        'relativePath': relativePath,
        'sha256': sha256,
        'size': size,
        'folderUri': folderUri,
        'folderName': folderName,
        'documentUri': documentUri,
        'savedAt': savedAt,
        'importConfirmed': importConfirmed,
      };

  factory SavedSystemFile.fromJson(Map<String, dynamic> json) =>
      SavedSystemFile(
        fileId: json['fileId'] as String,
        assetId: json['assetId'] as String,
        versionId: json['versionId'] as String,
        platformId: json['platformId'] as String,
        filename: json['filename'] as String,
        relativePath:
            json['relativePath'] as String? ?? json['filename'] as String,
        sha256: json['sha256'] as String,
        size: (json['size'] as num).toInt(),
        folderUri: json['folderUri'] as String,
        folderName: json['folderName'] as String? ?? '',
        documentUri: json['documentUri'] as String,
        savedAt: json['savedAt'] as String? ?? '',
        importConfirmed: json['importConfirmed'] == true,
      );
}

class SavedSystemFiles extends ChangeNotifier {
  SavedSystemFiles(this._prefs) {
    final raw = _prefs.getString(_key);
    if (raw == null) return;
    try {
      for (final item in jsonDecode(raw) as List) {
        final record =
            SavedSystemFile.fromJson(Map<String, dynamic>.from(item as Map));
        _records[record.fileId] = record;
      }
    } catch (e) {
      debugPrint('SavedSystemFiles: stored value is unreadable: $e');
    }
  }

  static const _key = 'system_files_saved';
  final SharedPreferences _prefs;
  final Map<String, SavedSystemFile> _records = {};

  SavedSystemFile? operator [](String fileId) => _records[fileId];

  Future<void> put(SavedSystemFile record) async {
    _records[record.fileId] = record;
    await _save();
  }

  Future<void> remove(String fileId) async {
    if (_records.remove(fileId) != null) await _save();
  }

  Future<void> _save() async {
    await _prefs.setString(
        _key, jsonEncode([for (final r in _records.values) r.toJson()]));
    notifyListeners();
  }
}
