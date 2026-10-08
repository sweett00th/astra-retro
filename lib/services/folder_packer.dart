import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Thrown when [FolderPacker.cancel] stops a pack that was under way.
class FolderPackCancelled implements Exception {
  const FolderPackCancelled();

  @override
  String toString() => 'Packing was cancelled';
}

/// Writes a folder as one `.zip`, for emulators that install a game from an
/// archive and cannot use a loose folder.
///
/// The work runs in its own isolate: a game is several gigabytes, and an
/// isolate can be stopped when the download is cancelled.
class FolderPacker {
  Isolate? _isolate;
  bool _cancelled = false;

  /// Packs every file under [sourceDir] into [zipPath], inside one top-level
  /// folder named [rootName]. Entries are stored, not compressed: game data
  /// is already compressed, so deflating it would only cost time.
  ///
  /// Throws [FolderPackCancelled] when [cancel] stops it. A partial archive
  /// may be left at [zipPath] after a failure; deleting it is up to the caller.
  Future<void> pack({
    required String sourceDir,
    required String zipPath,
    required String rootName,
  }) async {
    final events = ReceivePort();
    final done = Completer<void>();
    _cancelled = false;
    final subscription = events.listen((message) {
      if (done.isCompleted) return;
      if (message == true) {
        done.complete();
      } else if (message is List) {
        // An uncaught error in the isolate: [description, stack trace].
        done.completeError(FileSystemException('Could not pack the game: ${message.first}'));
      } else {
        // The isolate ended without finishing.
        done.completeError(_cancelled
            ? const FolderPackCancelled()
            : const FileSystemException('Packing the game stopped unexpectedly'));
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _pack,
        _PackRequest(events.sendPort, sourceDir, zipPath, rootName),
        onError: events.sendPort,
        onExit: events.sendPort,
      );
      // A cancel that arrived while the isolate was starting.
      if (_cancelled) _isolate?.kill(priority: Isolate.immediate);
      await done.future;
    } finally {
      _isolate = null;
      await subscription.cancel();
      events.close();
    }
  }

  /// Stops the pack in progress, if there is one.
  void cancel() {
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
  }
}

class _PackRequest {
  final SendPort port;
  final String sourceDir;
  final String zipPath;
  final String rootName;

  const _PackRequest(this.port, this.sourceDir, this.zipPath, this.rootName);
}

Future<void> _pack(_PackRequest request) async {
  final source = Directory(request.sourceDir);
  final files = source
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final encoder = ZipFileEncoder()
    ..create(request.zipPath, level: ZipFileEncoder.STORE);
  try {
    for (final file in files) {
      // Zip entry names always use forward slashes.
      final relative = p.split(p.relative(file.path, from: source.path));
      await encoder.addFile(
          file, [request.rootName, ...relative].join('/'), ZipFileEncoder.STORE);
    }
  } finally {
    await encoder.close();
  }
  request.port.send(true);
}
