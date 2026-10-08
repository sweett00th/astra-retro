import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_eshop/services/folder_packer.dart';

/// Repeatable filler bytes; nothing here is real game data.
Uint8List syntheticBytes(int length, {int seed = 0}) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xff));

void main() {
  late Directory tmp;
  late Directory source;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('folder_packer_test_');
    source = Directory(p.join(tmp.path, 'download'))..createSync();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a just-closed file for a moment; the OS clears temp.
    }
  });

  void write(String relative, List<int> bytes) {
    File(p.joinAll([source.path, ...relative.split('/')]))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  test('packs every file under one top-level folder, without compressing',
      () async {
    final files = {
      'PCSX00001/eboot.bin': syntheticBytes(300000, seed: 1),
      'PCSX00001/sce_sys/param.sfo': syntheticBytes(700, seed: 2),
      'PCSX00001/sce_sys/livearea/contents/bg.png': syntheticBytes(4096, seed: 3),
      'readme.txt': syntheticBytes(12, seed: 4),
    };
    files.forEach(write);
    final zipPath = p.join(tmp.path, 'library', 'Synthetic Game.zip');
    Directory(p.dirname(zipPath)).createSync();

    await FolderPacker().pack(
        sourceDir: source.path, zipPath: zipPath, rootName: 'Synthetic Game');

    final input = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeBuffer(input);
    final packed = {
      for (final file in archive.files)
        if (file.isFile) file.name: file.content as List<int>,
    };
    await input.close();
    expect(packed.keys.toSet(),
        {for (final name in files.keys) 'Synthetic Game/$name'});
    for (final entry in files.entries) {
      expect(packed['Synthetic Game/${entry.key}'], entry.value,
          reason: entry.key);
    }

    // Stored, not deflated: method 0 in the first local header, and the
    // archive is the files plus a little bookkeeping.
    final raw = File(zipPath).readAsBytesSync();
    expect(raw.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
    expect(ByteData.sublistView(raw).getUint16(8, Endian.little), 0);
    final total = files.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
    expect(raw.length, greaterThan(total));
    expect(raw.length, lessThan(total + 1024 * files.length));
  });

  test('a cancelled pack reports it, and the packer can be used again',
      () async {
    // Big enough that the pack cannot be over before the cancel lands.
    final big = File(p.join(source.path, 'big.bin')).openSync(mode: FileMode.write);
    big.truncateSync(256 * 1024 * 1024);
    big.closeSync();
    final packer = FolderPacker();

    final cancelled = packer.pack(
        sourceDir: source.path,
        zipPath: p.join(tmp.path, 'cancelled.zip'),
        rootName: 'Game');
    packer.cancel();
    await expectLater(cancelled, throwsA(isA<FolderPackCancelled>()));

    // Another folder: Windows keeps the stopped packer's file open a moment.
    final second = Directory(p.join(tmp.path, 'second'))..createSync();
    File(p.join(second.path, 'small.bin')).writeAsBytesSync(syntheticBytes(64));
    final zipPath = p.join(tmp.path, 'second.zip');
    await packer.pack(sourceDir: second.path, zipPath: zipPath, rootName: 'Game');
    final input = InputFileStream(zipPath);
    final names = ZipDecoder().decodeBuffer(input).files.map((f) => f.name);
    expect(names, ['Game/small.bin']);
    await input.close();
  });

  test('a failure inside the packer reaches the caller', () async {
    await expectLater(
      FolderPacker().pack(
          sourceDir: p.join(tmp.path, 'no-such-folder'),
          zipPath: p.join(tmp.path, 'never.zip'),
          rootName: 'Game'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
