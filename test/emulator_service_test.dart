import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/models/emulator.dart';
import 'package:retro_eshop/services/emulator_service.dart';
import 'package:retro_eshop/utils/friendly_error.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.retro.rshop/launcher');
  late Set<String> installed;
  late List<MethodCall> calls;
  String? failLaunch;

  setUp(() {
    installed = {};
    calls = [];
    failLaunch = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'installedPackages':
          final asked = (call.arguments['packages'] as List).cast<String>();
          return {
            for (final p in asked.where(installed.contains))
              p: {'label': p, 'versionName': '1.0'}
          };
        case 'launch':
          if (failLaunch != null) {
            throw PlatformException(code: 'NOT_FOUND', message: failLaunch);
          }
          return null;
        case 'openApp':
          return null;
      }
      return null;
    });
  });

  Future<EmulatorPreferences> prefs(
      [Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return EmulatorPreferences(await SharedPreferences.getInstance());
  }

  EmulatorOption option(String id, String? pkg) =>
      EmulatorOption(builtInEmulators.firstWhere((d) => d.id == id), pkg);

  test('RetroArch request carries the ROM path and the system core', () {
    final request = EmulatorService.launchRequest(
        option('retroarch', 'com.retroarch.aarch64'),
        '/storage/emulated/0/ROMs/n64/Game.z64',
        'n64');
    expect(request['package'], 'com.retroarch.aarch64');
    expect(request['action'], 'android.intent.action.MAIN');
    final extras = {
      for (final e in request['extras'] as List) (e as Map)['key']: e['value']
    };
    expect(extras['ROM'], '/storage/emulated/0/ROMs/n64/Game.z64');
    expect(extras['LIBRETRO'],
        '/data/data/com.retroarch.aarch64/cores/mupen64plus_next_gles3_libretro_android.so');
    expect(request['data'], isNull);
  });

  test('data-based emulators receive the ROM as the intent data', () {
    final request = EmulatorService.launchRequest(
        option('ppsspp', 'org.ppsspp.ppsspp'), '/roms/psp/Game.iso', 'psp');
    expect(request['data'], '/roms/psp/Game.iso');
    expect(request['mimeType'], isNull);
    final chooser = EmulatorService.launchRequest(
        const EmulatorOption(openWithEmulator, null),
        '/roms/psp/Game.iso',
        'psp');
    expect(chooser['package'], isNull);
    expect(chooser['mimeType'], 'application/octet-stream');
  });

  test('content-URI extras are marked for conversion on Android', () {
    final request = EmulatorService.launchRequest(
        option('duckstation', 'com.github.stenzek.duckstation'),
        '/roms/psx/Game.cue',
        'psx');
    final boot = (request['extras'] as List)
        .cast<Map>()
        .firstWhere((e) => e['key'] == 'bootPath');
    expect(boot['type'], 'uriString');
    expect(boot['value'], '/roms/psx/Game.cue');
  });

  test('only emulators for the system are offered, installed first', () async {
    installed = {'org.dolphinemu.dolphinemu'};
    final options = await EmulatorService().optionsFor('gc');
    expect(options.map((o) => o.id), ['dolphin', 'open-with']);
    expect(options.first.installed, true);
    final n64 = await EmulatorService().optionsFor('n64');
    expect(n64.map((o) => o.id), ['retroarch', 'open-with']);
    expect(n64.first.installed, false);
  });

  test('game choice beats system default beats first installed', () async {
    installed = {'com.retroarch.aarch64', 'com.github.stenzek.duckstation'};
    final service = EmulatorService();
    expect(
        (await service.resolve('psx', 'a.cue', await prefs())).id, 'retroarch');
    expect(
        (await service.resolve('psx', 'a.cue',
                await prefs({'emulator_system_psx': 'duckstation'})))
            .id,
        'duckstation');
    expect(
        (await service.resolve(
                'psx',
                'a.cue',
                await prefs({
                  'emulator_system_psx': 'duckstation',
                  'emulator_game_psx_a.cue': 'open-with',
                })))
            .id,
        'open-with');
  });

  test('ScummVM games open the ScummVM app, with a download page', () async {
    final options = await EmulatorService().optionsFor('scummvm');
    expect(options.map((o) => o.id), ['scummvm', 'open-with']);
    expect(options.first.definition.launchesFiles, false);
    expect(options.first.definition.homepage,
        startsWith('https://www.scummvm.org'));
  });
  test('nothing installed falls back to Open with', () async {
    final picked =
        await EmulatorService().resolve('gc', 'g.rvz', await prefs());
    expect(picked.id, 'open-with');
    expect(picked.installed, true);
  });

  test('launch errors are explained to the user', () async {
    final service = EmulatorService();
    await expectLater(
        service.launch(option('dolphin', null), '/r/g.rvz', 'gc'),
        throwsA(isA<UserFacingException>()
            .having((e) => e.message, 'message', contains('not installed'))));
    failLaunch = 'no activity';
    await expectLater(
        service.launch(
            option('dolphin', 'org.dolphinemu.dolphinemu'), '/r/g.rvz', 'gc'),
        throwsA(isA<UserFacingException>().having(
            (e) => e.message, 'message', contains('Could not start Dolphin'))));
  });

  test('install-based emulators are opened instead of given a file', () async {
    await EmulatorService()
        .launch(option('vita3k', 'org.vita3k.emulator'), '/r/game', 'psvita');
    expect(calls.single.method, 'openApp');
    expect(calls.single.arguments, {'package': 'org.vita3k.emulator'});
  });
}
