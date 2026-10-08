import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/game_item.dart';
import '../models/system_model.dart';

class RomManager {
  static String safePath(String baseDir, String filename) {
    final sanitized = p.basename(filename);
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      throw Exception('Invalid filename: path traversal detected');
    }
    return '$baseDir/$sanitized';
  }

  static String getTargetPath(
      GameItem game, SystemModel system, String targetFolder) {
    return safePath(targetFolder, getTargetFilename(game, system));
  }

  /// Archive formats the app can extract. `.7z` is excluded because it is
  /// downloaded as-is (not extracted), so its extension must be preserved.
  static const _extractableExtensions = ['.zip', '.rar'];

  /// Returns the filename a game would have after download (archive → ROM extension).
  static String getTargetFilename(GameItem game, SystemModel system) {
    var filename = p.basename(game.filename);

    for (final ext in _extractableExtensions) {
      if (filename.toLowerCase().endsWith(ext)) {
        filename = filename.substring(0, filename.length - ext.length);
        filename =
            '$filename${system.romExtensions.isNotEmpty ? system.romExtensions.first : ''}';
        break;
      }
    }

    return filename;
  }

  /// Name of the archive a folder-based game is saved as when its system
  /// packs folder games.
  static String packedFilename(String folderName) =>
      '${p.basename(folderName)}.zip';

  /// The names a game can go by in its system's ROM folder once it is on the
  /// device: as it is listed, extracted from its archive (a ROM or a folder),
  /// or, for a folder-based game, packed into one archive.
  static List<String> installedNames(String filename, SystemModel? system) {
    final lower = filename.toLowerCase();
    for (final ext in SystemModel.archiveExtensions) {
      if (!lower.endsWith(ext)) continue;
      final stripped = filename.substring(0, filename.length - ext.length);
      return [
        filename,
        stripped,
        if (system != null)
          for (final romExt in system.romExtensions) '$stripped$romExt',
      ];
    }
    return [filename, packedFilename(filename)];
  }

  /// The archive a folder-based [game] was packed into, if it is in
  /// [targetFolder]. A game that is an archive itself is never packed.
  static Future<File?> _packedArchive(GameItem game, String targetFolder) async {
    final name = p.basename(game.filename);
    final lower = name.toLowerCase();
    if (SystemModel.archiveExtensions.any(lower.endsWith)) return null;
    final file = File(safePath(targetFolder, packedFilename(name)));
    return await file.exists() ? file : null;
  }

  static String? extractGameName(String filename) {
    var name = filename;

    for (final ext in SystemModel.archiveExtensions) {
      if (name.toLowerCase().endsWith(ext)) {
        name = name.substring(0, name.length - ext.length);
        break;
      }
    }

    name = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();

    return name.isEmpty ? null : name;
  }

  static Future<List<GameItem>> scanLocalGames(
    SystemModel system,
    String targetFolder,
  ) async {
    try {
      final dir = Directory(targetFolder);
      if (!await dir.exists()) return [];

      final entities = await dir.list().toList();
      return _scanDirectory(
        entities,
        system.romExtensions,
        system.multiFileExtensions,
      );
    } on FileSystemException catch (e) {
      debugPrint('RomManager: cannot scan $targetFolder: $e');
      return [];
    }
  }

  /// Returns the actual file path of an installed ROM, or null if not found.
  /// Checks direct path first, then original archive, then subfolder fallback.
  static Future<String?> resolveInstalledPath(
      GameItem game, SystemModel system, String targetFolder) async {
    try {
      final directPath = getTargetPath(game, system, targetFolder);
      if (await File(directPath).exists()) return directPath;

      // Check if the original archive file exists (e.g. Game.zip not yet extracted)
      final basename = p.basename(game.filename);
      if (basename != p.basename(directPath)) {
        final archivePath = safePath(targetFolder, basename);
        if (await File(archivePath).exists()) return archivePath;
      }

      final packed = await _packedArchive(game, targetFolder);
      if (packed != null) return packed.path;

      final gameName = extractGameName(game.filename);
      if (gameName != null) {
        final subfolderPath = safePath(targetFolder, gameName);
        final subfolder = Directory(subfolderPath);
        if (await subfolder.exists()) {
          final validExts = {
            ...system.romExtensions.map((e) => e.toLowerCase()),
            ...?system.multiFileExtensions?.map((e) => e.toLowerCase()),
          };
          for (final file in subfolder.listSync()) {
            if (file is File) {
              final ext = p.extension(file.path).toLowerCase();
              if (validExts.contains(ext)) return file.path;
            }
          }
        }
      }

      return null;
    } on FileSystemException catch (e) {
      debugPrint('RomManager: resolveInstalledPath failed for ${game.filename}: $e');
      return null;
    }
  }

  /// Like [resolveInstalledPath], but returns a [SharePathResult] indicating
  /// whether the path is a single file or a directory (multi-file ROM).
  static Future<SharePathResult?> resolveSharePath(
      GameItem game, SystemModel system, String targetFolder) async {
    try {
      final directPath = getTargetPath(game, system, targetFolder);
      if (await File(directPath).exists()) {
        return SharePathResult(directPath, isDirectory: false);
      }

      final basename = p.basename(game.filename);
      if (basename != p.basename(directPath)) {
        final archivePath = safePath(targetFolder, basename);
        if (await File(archivePath).exists()) {
          return SharePathResult(archivePath, isDirectory: false);
        }
      }

      final packed = await _packedArchive(game, targetFolder);
      if (packed != null) {
        return SharePathResult(packed.path, isDirectory: false);
      }

      final gameName = extractGameName(game.filename);
      if (gameName != null) {
        final subfolderPath = safePath(targetFolder, gameName);
        final subfolder = Directory(subfolderPath);
        if (await subfolder.exists()) {
          final validExts = {
            ...system.romExtensions.map((e) => e.toLowerCase()),
            ...?system.multiFileExtensions?.map((e) => e.toLowerCase()),
          };
          // Verify subfolder actually contains ROM files
          final hasRomFiles = subfolder.listSync().any((f) =>
              f is File && validExts.contains(p.extension(f.path).toLowerCase()));
          if (hasRomFiles) {
            return SharePathResult(subfolderPath, isDirectory: true);
          }
        }
      }

      return null;
    } on FileSystemException catch (e) {
      debugPrint('RomManager: resolveSharePath failed for ${game.filename}: $e');
      return null;
    }
  }

  Future<bool> exists(
      GameItem game, SystemModel system, String targetFolder) async {
    try {
      final directPath = getTargetPath(game, system, targetFolder);
      if (await File(directPath).exists()) {
        return true;
      }

      // Check if the original archive file exists (e.g. Game.zip not yet extracted)
      final basename = p.basename(game.filename);
      if (basename != p.basename(directPath)) {
        final archivePath = safePath(targetFolder, basename);
        if (await File(archivePath).exists()) return true;
      }

      if (await _packedArchive(game, targetFolder) != null) return true;

      final gameName = extractGameName(game.filename);
      if (gameName != null) {
        final subfolderPath = safePath(targetFolder, gameName);
        final subfolder = Directory(subfolderPath);
        if (await subfolder.exists()) {
          final validExts = {
            ...system.romExtensions.map((e) => e.toLowerCase()),
            ...?system.multiFileExtensions?.map((e) => e.toLowerCase()),
          };
          final files = subfolder.listSync();
          for (final file in files) {
            if (file is File) {
              final ext = p.extension(file.path).toLowerCase();
              if (validExts.contains(ext)) {
                return true;
              }
            }
          }
        }
      }

      return false;
    } on FileSystemException catch (e) {
      debugPrint('RomManager: exists check failed for ${game.filename}: $e');
      return false;
    }
  }

  Future<Map<int, bool>> checkMultipleExists(
    List<GameItem> variants,
    SystemModel system,
    String targetFolder,
  ) async {
    final result = <int, bool>{};
    for (int i = 0; i < variants.length; i++) {
      result[i] = await exists(variants[i], system, targetFolder);
    }
    return result;
  }

  Future<void> delete(
      GameItem game, SystemModel system, String targetFolder) async {
    try {
      final path = getTargetPath(game, system, targetFolder);
      final file = File(path);
      if (await file.exists()) {
        final tracks = await sheetTrackFiles(file);
        await file.delete();
        for (final track in tracks) {
          try {
            await track.delete();
          } on FileSystemException catch (e) {
            debugPrint('RomManager: could not delete ${track.path}: $e');
          }
        }
        return;
      }

      // Check if the original archive file exists (e.g. Game.zip not extracted)
      final basename = p.basename(game.filename);
      if (basename != p.basename(path)) {
        final archivePath = safePath(targetFolder, basename);
        final archiveFile = File(archivePath);
        if (await archiveFile.exists()) {
          await archiveFile.delete();
          return;
        }
      }

      // A folder-based game saved as one archive; a loose copy of the same
      // game, if there is one too, goes with it below.
      await (await _packedArchive(game, targetFolder))?.delete();

      final gameName = extractGameName(game.filename);
      if (gameName != null) {
        final subfolderPath = safePath(targetFolder, gameName);
        final subfolder = Directory(subfolderPath);
        if (await subfolder.exists()) {
          await subfolder.delete(recursive: true);
        }
      }
    } on FileSystemException catch (e) {
      debugPrint('RomManager: delete failed for ${game.filename}: $e');
    }
  }

  static final _cueFileLine =
      RegExp(r'^\s*FILE\s+(?:"([^"]+)"|(\S+))', caseSensitive: false);
  static final _gdiTrackLine =
      RegExp(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+(?:"([^"]+)"|(\S+))\s+\d+');

  /// Track files a `.cue` or `.gdi` sheet names. They sit next to the sheet
  /// and belong to it alone, so they are deleted together with the game.
  static Future<List<File>> sheetTrackFiles(File sheet) async {
    final ext = p.extension(sheet.path).toLowerCase();
    if (ext != '.cue' && ext != '.gdi') return const [];
    final pattern = ext == '.cue' ? _cueFileLine : _gdiTrackLine;
    final tracks = <File>[];
    try {
      // Sheets are a few lines of text; anything large is not a sheet.
      if (await sheet.length() > 1024 * 1024) return const [];
      final text = utf8.decode(await sheet.readAsBytes(), allowMalformed: true);
      final names = <String>{};
      for (final line in const LineSplitter().convert(text)) {
        final match = pattern.firstMatch(line);
        final name = match?.group(1) ?? match?.group(2);
        if (name != null) names.add(name);
      }
      for (final name in names) {
        // Only plain names next to the sheet: never follow a path.
        if (p.basename(name) != name || name == p.basename(sheet.path)) continue;
        final track = File(p.join(sheet.parent.path, name));
        if (await track.exists()) tracks.add(track);
      }
    } on FileSystemException catch (e) {
      debugPrint('RomManager: could not read sheet ${sheet.path}: $e');
    }
    return tracks;
  }

  Future<Set<String>> getInstalledFilenames(
    List<GameItem> variants,
    SystemModel system,
    String targetFolder,
  ) async {
    final installed = <String>{};
    for (final variant in variants) {
      if (await exists(variant, system, targetFolder)) {
        installed.add(variant.filename);
      }
    }
    return installed;
  }

  Future<bool> isAnyVariantInstalled(
    List<GameItem> variants,
    SystemModel system,
    String targetFolder,
  ) async {
    for (final variant in variants) {
      if (await exists(variant, system, targetFolder)) {
        return true;
      }
    }
    return false;
  }

  /// Scans local games in an isolate. Used for bulk discovery where
  /// sequential scanning of many systems benefits from isolate offloading.
  static Future<List<GameItem>> scanLocalGamesIsolate(
    SystemModel system,
    String targetFolder,
  ) async {
    return compute(
      _scanLocalGamesIsolateEntry,
      _ScanParams(
        targetFolder: targetFolder,
        romExtensions: system.romExtensions,
        multiFileExtensions: system.multiFileExtensions,
      ),
    );
  }

  /// Shared 2-pass scan logic used by both main-thread and isolate scanners.
  static List<GameItem> _scanDirectory(
    List<FileSystemEntity> entities,
    List<String> romExtensions,
    List<String>? multiFileExtensions,
  ) {
    final allExtensions = [
      ...romExtensions.map((e) => e.toLowerCase()),
      ...SystemModel.archiveExtensions,
    ];
    final multiExts =
        multiFileExtensions?.map((e) => e.toLowerCase()).toList() ?? [];

    final dirNames = <String>{};
    final games = <GameItem>[];

    // Pass 1: Directories containing ROM files
    final subDirExts = {
      ...romExtensions.map((e) => e.toLowerCase()),
      ...multiExts,
    };
    for (final entity in entities) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      List<FileSystemEntity> subFiles;
      try {
        subFiles = entity.listSync(recursive: true);
      } on FileSystemException catch (e) {
        debugPrint('RomManager: cannot list subdirectory $name: $e');
        continue;
      }
      final hasMatchingFile = subFiles.any((f) =>
          f is File && subDirExts.contains(p.extension(f.path).toLowerCase()));
      if (hasMatchingFile) {
        dirNames.add(name);
        games.add(GameItem(
          filename: name,
          displayName: GameItem.cleanDisplayName(name),
          url: '',
        ));
      }
    }

    // Pass 2: Individual files (skip if a multi-file dir with same base name exists)
    for (final entity in entities) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final ext = p.extension(name).toLowerCase();
      if (!allExtensions.contains(ext)) continue;
      if (dirNames.contains(p.basenameWithoutExtension(name))) continue;
      games.add(GameItem(
        filename: name,
        displayName: GameItem.cleanDisplayName(name),
        url: '',
      ));
    }

    games.sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return games;
  }
}

/// Result of resolving a ROM's share path.
class SharePathResult {
  final String path;
  final bool isDirectory;
  const SharePathResult(this.path, {required this.isDirectory});
}

class _ScanParams {
  final String targetFolder;
  final List<String> romExtensions;
  final List<String>? multiFileExtensions;

  const _ScanParams({
    required this.targetFolder,
    required this.romExtensions,
    this.multiFileExtensions,
  });
}

Future<List<GameItem>> _scanLocalGamesIsolateEntry(_ScanParams params) async {
  try {
    final dir = Directory(params.targetFolder);
    if (!await dir.exists()) return [];

    final entities = await dir.list().toList();
    return RomManager._scanDirectory(
      entities,
      params.romExtensions,
      params.multiFileExtensions,
    );
  } on FileSystemException catch (e) {
    debugPrint('RomManager: isolate scan failed: $e');
    return [];
  }
}
