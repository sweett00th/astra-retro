import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_eshop/providers/installed_sizes_provider.dart';

void main() {
  late Directory roms;

  String folder(String system) => p.join(roms.path, system);

  File write(String relative, int bytes) => File(p.join(roms.path, relative))
    ..createSync(recursive: true)
    ..writeAsBytesSync(List.filled(bytes, 0));

  setUp(() =>
      roms = Directory.systemTemp.createTempSync('installed_sizes_test_'));
  tearDown(() => roms.deleteSync(recursive: true));

  test('a file counts itself, a folder everything inside it', () async {
    write('n64/Alpha.z64', 300);
    write('psvita/Bravo [PCSX00001]/eboot.bin', 100);
    write('psvita/Bravo [PCSX00001]/sce_sys/param.sfo', 20);
    write('psvita/Bravo [PCSX00001]/data/a/b/c.dat', 3);
    write('psvita/Charlie.zip', 50);
    Directory(p.join(folder('psvita'), 'Empty')).createSync();

    final sizes = await measureRomFolders({
      'n64': folder('n64'),
      'psvita': folder('psvita'),
    });

    expect(sizes.bySystem, {
      'n64': {'Alpha.z64': 300},
      'psvita': {'Bravo [PCSX00001]': 123, 'Charlie.zip': 50, 'Empty': 0},
    });
  });

  test('a system whose folder is not there yet has no sizes', () async {
    write('n64/Alpha.z64', 300);

    final sizes = await measureRomFolders({
      'n64': folder('n64'),
      'psx': folder('psx'),
    });

    expect(sizes.bySystem.keys, ['n64']);
  });

  test('a disc sheet counts the track files it names', () async {
    write('psx/Delta (Track 1).bin', 700);
    write('psx/Delta (Track 2).bin', 300);
    write('psx/Unrelated.bin', 5000);
    final sheet = File(p.join(folder('psx'), 'Delta.cue'))
      ..writeAsStringSync('FILE "Delta (Track 1).bin" BINARY\n'
          '  TRACK 01 MODE2/2352\n'
          '    INDEX 01 00:00:00\n'
          'FILE "Delta (Track 2).bin" BINARY\n'
          '  TRACK 02 AUDIO\n'
          '    INDEX 01 00:00:00\n');

    final sizes = (await measureRomFolders({'psx': folder('psx')}))
        .bySystem['psx']!;

    expect(sizes['Delta.cue'], sheet.lengthSync() + 1000);
    expect(sizes['Delta (Track 1).bin'], 700);
    expect(sizes['Unrelated.bin'], 5000);
  });
}
