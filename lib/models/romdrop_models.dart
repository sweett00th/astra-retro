import 'package:flutter/material.dart';

import 'system_model.dart';

/// What RomDrop's system-file API returns. These are emulator support files
/// (BIOS, firmware, keys), never games: nothing here is a [GameItem].

enum SystemFileKind {
  bios('bios', 'BIOS', Icons.memory_rounded),
  firmware('firmware', 'Firmware', Icons.system_update_alt_rounded),
  keys('keys', 'Keys', Icons.vpn_key_rounded),
  other('other', 'Other', Icons.folder_special_rounded);

  const SystemFileKind(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;

  static SystemFileKind? fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

T _require<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('RomDrop response is missing "$key".');
}

int _int(Map<String, dynamic> json, String key) =>
    _require<num>(json, key).toInt();

Map<String, dynamic> _map(Object? value, String what) {
  if (value is Map) return Map<String, dynamic>.from(value);
  throw FormatException('RomDrop response has no $what.');
}

List<Map<String, dynamic>> _list(Object? value, String what) {
  if (value is! List) throw FormatException('RomDrop response has no $what.');
  return [for (final item in value) _map(item, what)];
}

class RomDropCapabilities {
  final String apiVersion;
  final String serverVersion;
  final String deviceId;
  final String deviceName;
  final bool canSensitive;
  final bool isAdmin;
  final bool libraryAvailable;
  final String? libraryReason;
  final bool encrypted;

  const RomDropCapabilities({
    required this.apiVersion,
    required this.serverVersion,
    required this.deviceId,
    required this.deviceName,
    required this.canSensitive,
    required this.isAdmin,
    required this.libraryAvailable,
    this.libraryReason,
    required this.encrypted,
  });

  factory RomDropCapabilities.fromJson(Map<String, dynamic> json) {
    final principal = _map(json['principal'], 'principal');
    final permissions = _map(principal['permissions'], 'permissions');
    final library =
        _map(_map(json['features'], 'features')['system_library'], 'library');
    return RomDropCapabilities(
      apiVersion: _require<String>(json, 'api_version'),
      serverVersion:
          _map(json['server'], 'server')['version'] as String? ?? '',
      deviceId: _require<String>(principal, 'id'),
      deviceName: _require<String>(principal, 'name'),
      canSensitive: permissions['sensitive'] == true,
      isAdmin: permissions['admin'] == true,
      libraryAvailable: library['available'] == true,
      libraryReason: library['reason'] as String?,
      encrypted: _map(json['transport'], 'transport')['encrypted'] == true,
    );
  }
}

class SystemPlatform {
  final String id;
  final String name;
  final List<String> aliases;
  final int assetCount;
  final Map<SystemFileKind, int> kinds;
  final int hiddenSensitiveCount;

  const SystemPlatform({
    required this.id,
    required this.name,
    this.aliases = const [],
    this.assetCount = 0,
    this.kinds = const {},
    this.hiddenSensitiveCount = 0,
  });

  factory SystemPlatform.fromJson(Map<String, dynamic> json) {
    final rawKinds = json['kinds'];
    return SystemPlatform(
      id: _require<String>(json, 'id'),
      name: _require<String>(json, 'name'),
      aliases: [
        for (final alias in (json['aliases'] as List? ?? const []))
          alias.toString()
      ],
      assetCount: (json['asset_count'] as num?)?.toInt() ?? 0,
      kinds: {
        for (final kind in SystemFileKind.values)
          kind: rawKinds is Map ? (rawKinds[kind.id] as num?)?.toInt() ?? 0 : 0,
      },
      hiddenSensitiveCount:
          (json['hidden_sensitive_count'] as num?)?.toInt() ?? 0,
    );
  }

  int count(SystemFileKind kind) => kinds[kind] ?? 0;

  /// The R-Shop system this platform corresponds to, if it has one. RomDrop
  /// uses RetroArr's ids (ps1, vita, 3ds) and lists R-Shop's (psx, psvita,
  /// n3ds) as aliases. Used for the icon and accent colour only.
  SystemModel? get system {
    final names = {id, ...aliases};
    for (final system in SystemModel.supportedSystems) {
      if (names.contains(system.id)) return system;
    }
    return null;
  }
}

class SystemFileInfo {
  final String id;
  final String versionId;
  final String filename;
  final String relativePath;
  final int size;
  final String sha256;
  final String etag;

  /// ok, changed or missing on the server.
  final String state;

  /// The server's instruction for clients. Always false today: an archive
  /// here is the asset itself and must be saved as it is.
  final bool extract;
  final String downloadPath;

  const SystemFileInfo({
    required this.id,
    required this.versionId,
    required this.filename,
    required this.relativePath,
    required this.size,
    required this.sha256,
    required this.etag,
    this.state = 'ok',
    this.extract = false,
    required this.downloadPath,
  });

  factory SystemFileInfo.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final transfer = json['transfer'];
    final sha = _require<String>(json, 'sha256').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw const FormatException('RomDrop sent an invalid checksum.');
    }
    final path = _require<String>(json, 'download_path');
    if (!path.startsWith('/api/')) {
      throw const FormatException('RomDrop sent an invalid download path.');
    }
    // These become names of files and folders on this device.
    final filename = _require<String>(json, 'filename');
    final relativePath = _require<String>(json, 'relative_path');
    final segments = relativePath.split('/');
    if (segments.any((s) =>
            s.isEmpty ||
            s == '.' ||
            s == '..' ||
            s.contains('\\') ||
            s.codeUnits.any((unit) => unit < 0x20)) ||
        segments.last != filename) {
      throw const FormatException('RomDrop sent an unsafe file path.');
    }
    return SystemFileInfo(
      id: _require<String>(json, 'id'),
      versionId: _require<String>(json, 'version_id'),
      filename: filename,
      relativePath: relativePath,
      size: _int(json, 'size'),
      sha256: sha,
      etag: _require<String>(json, 'etag'),
      state: status is Map ? status['state'] as String? ?? 'ok' : 'ok',
      extract: transfer is Map && transfer['extract'] == true,
      downloadPath: path,
    );
  }

  bool get available => state == 'ok';

  /// Folders this file sits in within its version, outermost first. They
  /// are kept below the destination folder: "dc/dc_boot.bin" is saved into
  /// a "dc" folder there.
  List<String> get directories => relativePath.split('/')..removeLast();
}

class SystemAssetVersion {
  final String id;
  final String assetId;
  final String label;
  final bool preferred;
  final bool pinned;
  final bool deprecated;
  final String notes;
  final String createdAt;
  final int size;
  final List<SystemFileInfo> files;

  const SystemAssetVersion({
    required this.id,
    required this.assetId,
    this.label = '',
    this.preferred = false,
    this.pinned = false,
    this.deprecated = false,
    this.notes = '',
    this.createdAt = '',
    this.size = 0,
    this.files = const [],
  });

  factory SystemAssetVersion.fromJson(Map<String, dynamic> json) =>
      SystemAssetVersion(
        id: _require<String>(json, 'id'),
        assetId: _require<String>(json, 'asset_id'),
        label: json['label'] as String? ?? '',
        preferred: json['preferred'] == true,
        pinned: json['pinned'] == true,
        deprecated: json['deprecated'] == true,
        notes: json['notes'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        files: [
          for (final file in _list(json['files'], 'files'))
            SystemFileInfo.fromJson(file)
        ],
      );

  /// What to call this version on screen; the label may be unknown.
  String get displayLabel => label.isEmpty ? 'Unknown version' : label;

  /// Day the version was added, without the time.
  String get addedOn =>
      createdAt.length >= 10 ? createdAt.substring(0, 10) : createdAt;
}

class SystemAsset {
  final String id;
  final String platformId;
  final String platformName;
  final SystemFileKind kind;
  final String name;
  final bool sensitive;
  final String region;
  final String model;
  final String notes;
  final String installMethod;
  final String guidance;
  final String? preferredVersionId;
  final int versionCount;
  final SystemAssetVersion? preferredVersion;

  /// Newest first. Only filled by the single-asset endpoint.
  final List<SystemAssetVersion> versions;

  const SystemAsset({
    required this.id,
    required this.platformId,
    required this.platformName,
    required this.kind,
    required this.name,
    this.sensitive = false,
    this.region = '',
    this.model = '',
    this.notes = '',
    this.installMethod = '',
    this.guidance = '',
    this.preferredVersionId,
    this.versionCount = 0,
    this.preferredVersion,
    this.versions = const [],
  });

  factory SystemAsset.fromJson(Map<String, dynamic> json) {
    // A game must never be mistaken for a system file or the other way round.
    if (json['content_class'] != 'system_file') {
      throw const FormatException('RomDrop sent something that is not a system file.');
    }
    final platform = _map(json['platform'], 'platform');
    final kind = SystemFileKind.fromId(json['kind'] as String?);
    if (kind == null) {
      throw FormatException('Unknown system file kind: ${json['kind']}');
    }
    final preferred = json['preferred_version'];
    final versions = json['versions'];
    return SystemAsset(
      id: _require<String>(json, 'id'),
      platformId: _require<String>(platform, 'id'),
      platformName: _require<String>(platform, 'name'),
      kind: kind,
      name: _require<String>(json, 'name'),
      sensitive: json['sensitive'] == true,
      region: json['region'] as String? ?? '',
      model: json['model'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      installMethod: json['install_method'] as String? ?? '',
      guidance: json['guidance'] as String? ?? '',
      preferredVersionId: json['preferred_version_id'] as String?,
      versionCount: (json['version_count'] as num?)?.toInt() ?? 0,
      preferredVersion: preferred is Map
          ? SystemAssetVersion.fromJson(Map<String, dynamic>.from(preferred))
          : null,
      versions: versions is List
          ? [
              for (final version in _list(versions, 'versions'))
                SystemAssetVersion.fromJson(version)
            ]
          : const [],
    );
  }

  /// One line under the asset name: region and model when the admin set them.
  String get detailLine =>
      [region, model].where((part) => part.isNotEmpty).join(' · ');

  /// What the user does with the file once it is on the device. Saving it
  /// never installs it in an emulator.
  String get afterDownload {
    final method = switch (installMethod) {
      'copy_to_folder' =>
        'Save it into the folder your emulator reads this file from.',
      'emulator_import' =>
        'Open your emulator and import the saved file from its settings.',
      'manual' => 'Follow the notes below to finish in your emulator.',
      _ => 'Open your emulator and point it at, or import, the saved file.',
    };
    return guidance.isEmpty ? method : '$method\n$guidance';
  }
}

class RomDropAssetPage {
  final List<SystemAsset> items;
  final String? nextCursor;
  const RomDropAssetPage(this.items, this.nextCursor);

  factory RomDropAssetPage.fromJson(Map<String, dynamic> json) =>
      RomDropAssetPage(
        [for (final item in _list(json['items'], 'items')) SystemAsset.fromJson(item)],
        json['next_cursor'] as String?,
      );
}

String formatSystemFileSize(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}
