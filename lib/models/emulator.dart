/// How an emulator is started. Everything here is data so emulators can be
/// added or corrected without touching launch logic.
enum EmulatorExtraType { string, bool, uri, uriString }

/// An Intent extra. String values may use `{path}` (absolute ROM path),
/// `{pkg}` (installed package) and `{core}` (RetroArch core for the system).
/// `uri`/`uriString` values are turned into a content:// URI for `{path}`.
class EmulatorExtra {
  final String key;
  final EmulatorExtraType type;
  final Object value;

  const EmulatorExtra(this.key, this.value,
      [this.type = EmulatorExtraType.string]);
}

class EmulatorDefinition {
  final String id;
  final String name;

  /// Candidate package names; the first installed one is used.
  final List<String> packages;

  /// Explicit activity (absolute, or relative to the package with a leading
  /// dot). Null lets Android pick the package's matching activity.
  final String? activity;
  final String action;

  /// Pass the ROM as the Intent's data (a content:// URI).
  final bool romAsData;
  final List<EmulatorExtra> extras;

  /// R-Shop system ids this emulator runs.
  final List<String> systems;

  /// Per-system values for `{core}`.
  final Map<String, String> cores;

  /// False for emulators that only run games installed inside them (Vita,
  /// PS3): R-Shop opens the app instead of a file.
  final bool launchesFiles;

  /// Confirmed against the installed app on a real device.
  final bool verified;

  /// Official download page, offered when the emulator is not installed.
  final String? homepage;

  /// How to reach a game's settings (cheats, patches, per-game options)
  /// inside the emulator. Emulators keep those screens private, so R-Shop
  /// opens the emulator and shows these steps.
  final List<String> settingsSteps;

  const EmulatorDefinition({
    required this.id,
    required this.name,
    required this.packages,
    required this.systems,
    this.activity,
    this.action = 'android.intent.action.VIEW',
    this.romAsData = false,
    this.extras = const [],
    this.cores = const {},
    this.launchesFiles = true,
    this.verified = false,
    this.homepage,
    this.settingsSteps = const [],
  });

  bool supports(String systemId) =>
      systems.contains(systemId) &&
      (cores.isEmpty || cores.containsKey(systemId));
}

/// A definition resolved against what is installed.
class EmulatorOption {
  final EmulatorDefinition definition;

  /// Installed package, or null when the emulator is not installed.
  final String? package;
  final String? versionName;

  const EmulatorOption(this.definition, this.package, [this.versionName]);

  bool get installed => package != null || definition.packages.isEmpty;
  String get id => definition.id;
  String get name => definition.name;
}
