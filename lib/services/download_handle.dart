import 'dart:io';

typedef FtpProgressCallback = void Function(double percent, int received, int total);

sealed class DownloadHandle {
  const DownloadHandle();
}

final class HttpDownloadHandle extends DownloadHandle {
  final String url;
  final Map<String, String>? headers;

  /// False for authenticated sources so credentials never follow a redirect
  /// to another host.
  final bool followRedirects;

  /// Size reported by the source, used for the free-space check.
  final int? expectedBytes;

  const HttpDownloadHandle({
    required this.url,
    this.headers,
    this.followRedirects = true,
    this.expectedBytes,
  });
}

class HttpFolderFile {
  /// Path relative to the game's install location (validated before use).
  final String relativePath;
  final String url;
  final int size;

  const HttpFolderFile(
      {required this.relativePath, required this.url, required this.size});
}

/// Several HTTP files that make up one game (e.g. .cue + .bin tracks, or a
/// folder-based game). Installed into `targetFolder/subfolder/` when
/// [subfolder] is set, otherwise directly into the system folder.
final class HttpFolderDownloadHandle extends DownloadHandle {
  final List<HttpFolderFile> files;
  final Map<String, String>? headers;
  final String? subfolder;
  final bool followRedirects;

  /// Stable key so a retried download resumes the same partial files.
  final String resumeKey;

  const HttpFolderDownloadHandle({
    required this.files,
    required this.resumeKey,
    this.headers,
    this.subfolder,
    this.followRedirects = true,
  });

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
}

final class NativeSmbDownloadHandle extends DownloadHandle {
  final String host;
  final int port;
  final String share;
  final String filePath;
  final String user;
  final String pass;
  final String domain;

  const NativeSmbDownloadHandle({
    required this.host,
    required this.port,
    required this.share,
    required this.filePath,
    required this.user,
    required this.pass,
    required this.domain,
  });
}

final class FtpDownloadHandle extends DownloadHandle {
  final Future<void> Function(File destination, {FtpProgressCallback? onProgress}) downloadToFile;
  final Future<void> Function()? disconnect;

  const FtpDownloadHandle({required this.downloadToFile, this.disconnect});
}

/// Represents a single file inside a remote SMB folder.
class SmbFolderEntry {
  final String path;
  final String name;
  final int size;

  const SmbFolderEntry({required this.path, required this.name, required this.size});
}

final class NativeSmbFolderDownloadHandle extends DownloadHandle {
  final String host;
  final int port;
  final String share;
  final String folderPath;
  final String user;
  final String pass;
  final String domain;

  const NativeSmbFolderDownloadHandle({
    required this.host,
    required this.port,
    required this.share,
    required this.folderPath,
    required this.user,
    required this.pass,
    required this.domain,
  });
}

final class FtpFolderDownloadHandle extends DownloadHandle {
  final Future<List<String>> Function() listFiles;
  final Future<void> Function(String remotePath, File dest, {FtpProgressCallback? onProgress}) downloadFile;
  final Future<void> Function()? disconnect;

  const FtpFolderDownloadHandle({required this.listFiles, required this.downloadFile, this.disconnect});
}
