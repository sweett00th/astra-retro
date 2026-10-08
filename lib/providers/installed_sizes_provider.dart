import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../services/rom_manager.dart';
import 'game_providers.dart';
import 'rom_status_providers.dart';

/// How many bytes each entry of the systems' ROM folders takes on the device.
class InstalledSizes {
  const InstalledSizes([this.bySystem = const {}]);

  /// systemId → name of a file or folder directly inside that system's ROM
  /// folder → its size. A folder counts everything inside it, a disc sheet
  /// the track files it names.
  final Map<String, Map<String, int>> bySystem;
}

/// Sizes of everything in the ROM folders, measured off the UI isolate.
/// Measured again whenever [romChangeSignalProvider] bumps. Kept apart from
/// the installed-files index: that one must be quick, and walking large
/// folder games takes longer.
final installedSizesProvider = FutureProvider<InstalledSizes>((ref) async {
  ref.watch(romChangeSignalProvider);
  final config = await ref.watch(bootstrappedConfigProvider.future);
  return compute(measureRomFolders, {
    for (final system in config.systems)
      if (system.targetFolder.isNotEmpty) system.id: system.targetFolder,
  });
});

/// Measures the ROM folders in [foldersBySystem] (systemId → folder).
Future<InstalledSizes> measureRomFolders(
    Map<String, String> foldersBySystem) async {
  final bySystem = <String, Map<String, int>>{};
  for (final entry in foldersBySystem.entries) {
    final folder = Directory(entry.value);
    if (!folder.existsSync()) continue;
    final sizes = <String, int>{};
    final sheets = <File>[];
    try {
      for (final entity in folder.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is File) {
          sizes[name] = _fileSize(entity);
          final ext = p.extension(name).toLowerCase();
          if (ext == '.cue' || ext == '.gdi') sheets.add(entity);
        } else if (entity is Directory) {
          sizes[name] = _folderSize(entity);
        }
      }
    } on FileSystemException catch (e) {
      debugPrint('InstalledSizes: cannot list ${entry.value}: $e');
    }
    // A disc sheet is a few lines of text; the game is in the track files
    // it names, so they count towards it.
    for (final sheet in sheets) {
      final name = p.basename(sheet.path);
      for (final track in await RomManager.sheetTrackFiles(sheet)) {
        sizes[name] = (sizes[name] ?? 0) + _fileSize(track);
      }
    }
    bySystem[entry.key] = sizes;
  }
  return InstalledSizes(bySystem);
}

int _fileSize(File file) {
  try {
    return file.lengthSync();
  } on FileSystemException {
    return 0;
  }
}

int _folderSize(Directory folder) {
  var total = 0;
  try {
    for (final entity in folder.listSync(recursive: true, followLinks: false)) {
      if (entity is File) total += _fileSize(entity);
    }
  } on FileSystemException catch (e) {
    debugPrint('InstalledSizes: cannot walk ${folder.path}: $e');
  }
  return total;
}
