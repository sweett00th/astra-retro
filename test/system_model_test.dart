import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/models/system_model.dart';
import 'package:retro_eshop/services/retroarr_api_service.dart';
import 'package:retro_eshop/utils/game_metadata.dart';

void main() {
  test('system ids are unique', () {
    final ids = SystemModel.supportedSystems.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('every system logo is bundled', () {
    for (final system in SystemModel.supportedSystems) {
      if (system.iconName.isEmpty) continue;
      expect(File(system.iconAssetPath).existsSync(), isTrue,
          reason: '${system.id}: ${system.iconAssetPath}');
    }
  });

  group('PlayStation 4', () {
    final ps4 = SystemModel.supportedSystems.firstWhere((s) => s.id == 'ps4');

    test('sits with the other PlayStation systems', () {
      final ids = SystemModel.supportedSystems.map((s) => s.id).toList();
      expect(ids.indexOf('ps4'), ids.indexOf('ps3') + 1);
      expect(ps4.name, 'PlayStation 4');
      expect(ps4.manufacturer, 'Sony');
    });

    test("RetroArr's PlayStation 4 platform maps to it", () {
      // As listed by RetroArr's GET /api/v3/platform.
      const platforms = [
        RetroArrPlatform(22, 'PlayStation 3', 'ps3', 'ps3', 9),
        RetroArrPlatform(23, 'PlayStation 4', 'ps4', 'ps4', 48),
      ];
      final known = RetroArrPlatform.matchSystems(
          SystemModel.supportedSystems.map((s) => s.id), platforms);
      expect(known, {'ps3': 22, 'ps4': 23});
    });

    test('a game folder named with the .ps4 suffix shows a clean title', () {
      expect(GameMetadata.cleanTitle('Bloodborne.ps4'), 'Bloodborne');
      expect(GameMetadata.fileTitle('Bloodborne (USA).ps4'), 'Bloodborne (USA)');
    });
  });
}
