import '../system_model.dart';
import 'provider_config.dart';
import 'source.dart';

class SystemConfig {
  final String id;
  final String name;
  final String targetFolder;

  /// Legacy provider list. Kept alive during the v2 → v3 transition so that
  /// existing services keep working unchanged. New code should consume
  /// [Source]s from `AppConfig.sources` via the resolver instead. The
  /// migration step keeps `providers` and the new fields in sync; once all
  /// callers move over, this field will be removed.
  final List<ProviderConfig> providers;

  final bool autoExtract;
  final bool autoSync;

  /// Whether a game stored as a folder is saved as one `.zip`. `null` follows
  /// the system's default ([SystemModel.packFolderGames]); [packsFolderGames]
  /// is the value in effect.
  final bool? packFolders;

  /// Optional explicit allow-list of source ids that contribute to this
  /// system. `null` means "use every auto-mapped source plus everything in
  /// [manualMappings]" (the default after migration). A non-null list lets
  /// power users opt out of specific RomMs for a given system without
  /// touching their global priority.
  final List<String>? enabledSourceIds;

  /// Per-system pointers into manual sources (SMB/FTP/Web). Empty for
  /// pure-RomM setups since RomM advertises its platforms automatically.
  final List<SystemSourceMapping> manualMappings;

  const SystemConfig({
    required this.id,
    required this.name,
    required this.targetFolder,
    required this.providers,
    this.autoExtract = false,
    this.autoSync = true,
    this.packFolders,
    this.enabledSourceIds,
    this.manualMappings = const [],
  });

  /// Whether folder-based games of this system are saved as one `.zip`: the
  /// user's choice, or the system's default while they have not made one.
  bool get packsFolderGames =>
      packFolders ??
      SystemModel.supportedSystems.any((s) => s.id == id && s.packFolderGames);

  factory SystemConfig.fromJson(Map<String, dynamic> json) {
    final providerList = (json['providers'] as List<dynamic>? ?? const [])
        .map((e) => ProviderConfig.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));

    final mappings = (json['manual_mappings'] as List<dynamic>?)
            ?.map((e) =>
                SystemSourceMapping.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <SystemSourceMapping>[];

    final allowList = (json['enabled_source_ids'] as List<dynamic>?)
        ?.map((e) => e.toString())
        .toList();

    return SystemConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      targetFolder: json['target_folder'] as String,
      providers: providerList,
      autoExtract: json['auto_extract'] as bool? ?? false,
      autoSync: json['auto_sync'] as bool? ?? true,
      packFolders: json['pack_folders'] as bool?,
      enabledSourceIds: allowList,
      manualMappings: mappings,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'target_folder': targetFolder,
      'providers': providers.map((p) => p.toJson()).toList(),
      'auto_extract': autoExtract,
      'auto_sync': autoSync,
      if (packFolders != null) 'pack_folders': packFolders,
      if (enabledSourceIds != null) 'enabled_source_ids': enabledSourceIds,
      if (manualMappings.isNotEmpty)
        'manual_mappings': manualMappings.map((m) => m.toJson()).toList(),
    };
  }

  /// Like [toJson] but strips auth credentials from all providers.
  Map<String, dynamic> toJsonWithoutAuth() {
    return {
      'id': id,
      'name': name,
      'target_folder': targetFolder,
      'providers': providers.map((p) => p.toJsonWithoutAuth()).toList(),
      'auto_extract': autoExtract,
      'auto_sync': autoSync,
      if (packFolders != null) 'pack_folders': packFolders,
      if (enabledSourceIds != null) 'enabled_source_ids': enabledSourceIds,
      if (manualMappings.isNotEmpty)
        'manual_mappings': manualMappings.map((m) => m.toJson()).toList(),
    };
  }

  SystemConfig copyWith({
    String? id,
    String? name,
    String? targetFolder,
    List<ProviderConfig>? providers,
    bool? autoExtract,
    bool? autoSync,
    bool? packFolders,
    List<String>? enabledSourceIds,
    bool clearEnabledSourceIds = false,
    List<SystemSourceMapping>? manualMappings,
  }) {
    return SystemConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      targetFolder: targetFolder ?? this.targetFolder,
      providers: providers ?? this.providers,
      autoExtract: autoExtract ?? this.autoExtract,
      autoSync: autoSync ?? this.autoSync,
      packFolders: packFolders ?? this.packFolders,
      enabledSourceIds: clearEnabledSourceIds
          ? null
          : (enabledSourceIds ?? this.enabledSourceIds),
      manualMappings: manualMappings ?? this.manualMappings,
    );
  }
}
