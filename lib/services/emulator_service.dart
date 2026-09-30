import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/emulator.dart';
import '../utils/friendly_error.dart';

const _retroArchCores = {
  'nes': 'fceumm',
  'fds': 'fceumm',
  'snes': 'snes9x',
  'n64': 'mupen64plus_next_gles3',
  'gb': 'gambatte',
  'gbc': 'gambatte',
  'gba': 'mgba',
  'nds': 'melonds',
  'virtualboy': 'mednafen_vb',
  'psx': 'swanstation',
  'psp': 'ppsspp',
  'mastersystem': 'genesis_plus_gx',
  'megadrive': 'genesis_plus_gx',
  'gamegear': 'genesis_plus_gx',
  'segacd': 'genesis_plus_gx',
  'sg1000': 'genesis_plus_gx',
  'sega32x': 'picodrive',
  'saturn': 'yabasanshiro',
  'dreamcast': 'flycast',
  'tg16': 'mednafen_pce_fast',
  'tgcd': 'mednafen_pce_fast',
  'ngp': 'mednafen_ngp',
  'wonderswan': 'mednafen_wswan',
  'atari2600': 'stella',
  'atari7800': 'prosystem',
  'lynx': 'handy',
  'arcade': 'fbneo',
  'neogeocd': 'neocd',
};

/// Built-in emulators. Unverified entries follow commonly used launch
/// conventions and are confirmed against installed apps before being marked
/// verified; "Open with…" always remains as a fallback.
const builtInEmulators = <EmulatorDefinition>[
  EmulatorDefinition(
    id: 'retroarch',
    name: 'RetroArch',
    packages: ['com.retroarch.aarch64', 'com.retroarch', 'com.retroarch.ra32'],
    activity: 'com.retroarch.browser.retroactivity.RetroActivityFuture',
    action: 'android.intent.action.MAIN',
    extras: [
      EmulatorExtra('ROM', '{path}'),
      EmulatorExtra(
          'LIBRETRO', '/data/data/{pkg}/cores/{core}_libretro_android.so'),
      EmulatorExtra('CONFIGFILE',
          '/storage/emulated/0/Android/data/{pkg}/files/retroarch.cfg'),
    ],
    systems: [..._retroArchSystems],
    cores: _retroArchCores,
    homepage: 'https://www.retroarch.com/?page=platforms',
  ),
  EmulatorDefinition(
    id: 'dolphin',
    name: 'Dolphin',
    packages: ['org.dolphinemu.dolphinemu', 'org.dolphinemu.mmjr'],
    activity: 'org.dolphinemu.dolphinemu.ui.main.MainActivity',
    action: 'android.intent.action.MAIN',
    extras: [EmulatorExtra('AutoStartFile', '{path}')],
    systems: ['gc', 'wii'],
    homepage: 'https://dolphin-emu.org/download/',
  ),
  EmulatorDefinition(
    id: 'ppsspp',
    name: 'PPSSPP',
    packages: ['org.ppsspp.ppssppgold', 'org.ppsspp.ppsspp'],
    activity: 'org.ppsspp.ppsspp.PpssppActivity',
    romAsData: true,
    systems: ['psp'],
    homepage: 'https://www.ppsspp.org/download/',
  ),
  EmulatorDefinition(
    id: 'duckstation',
    name: 'DuckStation',
    packages: ['com.github.stenzek.duckstation'],
    activity: 'com.github.stenzek.duckstation.EmulationActivity',
    action: 'android.intent.action.MAIN',
    extras: [
      EmulatorExtra('bootPath', '{path}', EmulatorExtraType.uriString),
      EmulatorExtra('resumeState', false, EmulatorExtraType.bool),
    ],
    systems: ['psx'],
    homepage: 'https://www.duckstation.org/',
  ),
  EmulatorDefinition(
    id: 'nethersx2',
    name: 'NetherSX2 / AetherSX2',
    packages: ['xyz.aethersx2.android'],
    activity: 'xyz.aethersx2.android.EmulationActivity',
    action: 'android.intent.action.MAIN',
    extras: [EmulatorExtra('bootPath', '{path}', EmulatorExtraType.uriString)],
    systems: ['ps2'],
  ),
  EmulatorDefinition(
    id: 'melonds',
    name: 'melonDS',
    packages: ['me.magnum.melonds', 'me.magnum.melonds.nightly'],
    activity: 'me.magnum.melonds.ui.emulator.EmulatorActivity',
    action: 'android.intent.action.MAIN',
    extras: [EmulatorExtra('uri', '{path}', EmulatorExtraType.uriString)],
    systems: ['nds'],
  ),
  EmulatorDefinition(
    id: 'azahar',
    name: 'Azahar',
    packages: ['org.azahar_emu.azahar', 'io.github.lime3ds.android'],
    romAsData: true,
    systems: ['n3ds'],
    homepage: 'https://azahar-emu.org/',
  ),
  EmulatorDefinition(
    id: 'eden',
    name: 'Eden / Citron',
    packages: [
      'dev.eden.eden_emulator',
      'org.citron.citron_emu',
      'dev.legacy.eden_emulator'
    ],
    romAsData: true,
    systems: ['switch'],
  ),
  EmulatorDefinition(
    id: 'vita3k',
    name: 'Vita3K',
    packages: ['org.vita3k.emulator'],
    systems: ['psvita'],
    launchesFiles: false,
    homepage: 'https://vita3k.org/',
  ),
  // ScummVM keeps its own game list; R-Shop opens it until direct per-game
  // launch is verified against the installed app.
  EmulatorDefinition(
    id: 'scummvm',
    name: 'ScummVM',
    packages: ['org.scummvm.scummvm', 'org.scummvm.scummvm.debug'],
    systems: ['scummvm'],
    launchesFiles: false,
    homepage: 'https://www.scummvm.org/downloads/',
  ),
  EmulatorDefinition(
    id: 'rpcs3',
    name: 'RPCS3',
    packages: ['net.rpcs3', 'aenu.aps3e'],
    systems: ['ps3'],
    launchesFiles: false,
  ),
];

const _retroArchSystems = [
  'nes',
  'fds',
  'snes',
  'n64',
  'gb',
  'gbc',
  'gba',
  'nds',
  'virtualboy',
  'psx',
  'psp',
  'mastersystem',
  'megadrive',
  'gamegear',
  'segacd',
  'sg1000',
  'sega32x',
  'saturn',
  'dreamcast',
  'tg16',
  'tgcd',
  'ngp',
  'wonderswan',
  'atari2600',
  'atari7800',
  'lynx',
  'arcade',
  'neogeocd',
];

/// Android's "Open with…" chooser: any installed app that opens the file.
const openWithEmulator = EmulatorDefinition(
  id: 'open-with',
  name: 'Open with… (choose app)',
  packages: [],
  romAsData: true,
  systems: [],
);

/// Remembers the emulator per system and per game.
class EmulatorPreferences {
  EmulatorPreferences(this._prefs);
  final SharedPreferences _prefs;

  static String _systemKey(String systemId) => 'emulator_system_$systemId';
  static String _gameKey(String systemId, String filename) =>
      'emulator_game_${systemId}_$filename';

  String? systemDefault(String systemId) =>
      _prefs.getString(_systemKey(systemId));
  String? gameOverride(String systemId, String filename) =>
      _prefs.getString(_gameKey(systemId, filename));

  Future<void> setSystemDefault(String systemId, String? emulatorId) =>
      emulatorId == null
          ? _prefs.remove(_systemKey(systemId))
          : _prefs.setString(_systemKey(systemId), emulatorId);

  Future<void> setGameOverride(
          String systemId, String filename, String? emulatorId) =>
      emulatorId == null
          ? _prefs.remove(_gameKey(systemId, filename))
          : _prefs.setString(_gameKey(systemId, filename), emulatorId);
}

class EmulatorService {
  EmulatorService({
    List<EmulatorDefinition> definitions = builtInEmulators,
    MethodChannel channel = const MethodChannel('com.retro.rshop/launcher'),
  })  : _definitions = definitions,
        _channel = channel;

  final List<EmulatorDefinition> _definitions;
  final MethodChannel _channel;

  /// Emulators for a system (installed first), then "Open with…".
  Future<List<EmulatorOption>> optionsFor(String systemId) async {
    final candidates = _definitions.where((d) => d.supports(systemId)).toList();
    final installed = await _installed(candidates.expand((d) => d.packages));
    final options = [
      for (final d in candidates)
        EmulatorOption(
          d,
          d.packages.where(installed.containsKey).firstOrNull,
          installed[d.packages.where(installed.containsKey).firstOrNull],
        ),
    ]..sort((a, b) => (b.installed ? 1 : 0) - (a.installed ? 1 : 0));
    return [...options, const EmulatorOption(openWithEmulator, null)];
  }

  /// Per-game choice, else the system default, else the first installed
  /// emulator, else "Open with…".
  Future<EmulatorOption> resolve(
      String systemId, String filename, EmulatorPreferences prefs) async {
    final options = await optionsFor(systemId);
    for (final id in [
      prefs.gameOverride(systemId, filename),
      prefs.systemDefault(systemId),
    ]) {
      final match = options.where((o) => o.id == id).firstOrNull;
      if (match != null) return match;
    }
    return options.firstWhere((o) => o.installed);
  }

  Future<Map<String, String?>> _installed(Iterable<String> packages) async {
    final list = packages.toSet().toList();
    if (list.isEmpty) return const {};
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
          'installedPackages', {'packages': list});
      return {
        for (final e in (result ?? const {}).entries)
          e.key: (e.value as Map?)?['versionName'] as String?,
      };
    } on MissingPluginException {
      return const {};
    }
  }

  /// Builds the Intent description sent to the Android launcher.
  static Map<String, Object?> launchRequest(
      EmulatorOption option, String romPath, String systemId) {
    final d = option.definition;
    final pkg = option.package;
    String fill(String template) => template
        .replaceAll('{path}', romPath)
        .replaceAll('{pkg}', pkg ?? '')
        .replaceAll('{core}', d.cores[systemId] ?? '');
    return {
      'package': pkg,
      'activity': d.activity,
      'action': d.action,
      'data': d.romAsData ? romPath : null,
      'mimeType':
          d.romAsData && pkg == null ? 'application/octet-stream' : null,
      'extras': [
        for (final e in d.extras)
          {
            'key': e.key,
            'type': e.type.name,
            'value': e.value is String ? fill(e.value as String) : e.value,
          },
      ],
    };
  }

  /// Starts [romPath] in the chosen emulator. Emulators that only run
  /// games installed inside them are opened instead.
  Future<void> launch(
      EmulatorOption option, String romPath, String systemId) async {
    if (!option.installed) {
      throw UserFacingException('${option.name} is not installed. Install it '
          'or pick another emulator for this game.');
    }
    try {
      if (!option.definition.launchesFiles) {
        await _channel.invokeMethod('openApp', {'package': option.package});
        return;
      }
      await _channel.invokeMethod(
          'launch', launchRequest(option, romPath, systemId));
    } on PlatformException catch (e) {
      throw UserFacingException(
          'Could not start ${option.name}: ${e.message ?? e.code}. '
          'Try another emulator for this game.');
    }
  }
}
