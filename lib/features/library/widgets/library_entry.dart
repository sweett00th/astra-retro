import '../../../models/config/provider_config.dart';

class LibraryEntry {
  final String filename;
  final String displayName;
  final String cardTitle;
  final String url;
  final String? coverUrl;
  final String systemSlug;
  final ProviderConfig? providerConfig;
  final bool hasThumbnail;

  const LibraryEntry({
    required this.filename,
    required this.displayName,
    required this.cardTitle,
    required this.url,
    this.coverUrl,
    required this.systemSlug,
    this.providerConfig,
    this.hasThumbnail = false,
  });

  /// Identity across tabs and reloads: a filename is unique per system.
  String get key => '$systemSlug/$filename';

  /// Comes from a source, so it can be downloaded when not installed.
  bool get isRemote => url.isNotEmpty || providerConfig != null;
}
