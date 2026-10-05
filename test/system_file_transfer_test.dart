import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retro_eshop/models/romdrop_models.dart';
import 'package:retro_eshop/services/romdrop/romdrop_api_service.dart';
import 'package:retro_eshop/services/romdrop/system_file_download_manager.dart';
import 'package:retro_eshop/services/romdrop/system_file_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/romdrop_fakes.dart';

/// Transfers run against a server on loopback, so this file must not
/// initialise the Flutter test binding (it replaces HttpClient).
void main() {
  const folder = SystemFileFolder('tree:bios', 'Internal storage/Emulation/bios');
  final content = syntheticBytes(200 * 1024);
  final file = systemFile(content);

  late FixtureServer server;
  late Directory temp;
  late Directory staging;
  late FakeSystemFileStorage storage;
  late SharedPreferences prefs;
  late SavedSystemFiles saved;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    saved = SavedSystemFiles(prefs);
    temp = await Directory.systemTemp.createTemp('rshop_system_files_');
    staging = Directory(p.join(temp.path, 'staging'));
    storage = FakeSystemFileStorage()..folders[folder.uri] = {};
    server = await FixtureServer.start();
    server.handler = (request) => serveSystemFile(request, content);
  });

  tearDown(() async {
    await server.close();
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
        break;
      } on FileSystemException {
        // A transfer that was just stopped may still be letting go of a file.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  SystemFileRequest requestFor(SystemFileInfo file, {bool replace = false}) =>
      SystemFileRequest(
        file: file,
        assetId: 'ast_test000000000001',
        assetName: 'Synthetic BIOS',
        platformId: 'ps1',
        versionLabel: '1.0',
        folder: folder,
        replace: replace,
      );

  SystemFileTransfer transferFor(
    SystemFileInfo file, {
    bool replace = false,
    Duration stallTimeout = const Duration(seconds: 60),
    void Function(SystemFileTaskStatus status, int bytes)? onStatus,
  }) =>
      SystemFileTransfer(
        request: requestFor(file, replace: replace),
        uri: Uri.parse('${server.url}${file.downloadPath}'),
        headers: const {'Authorization': 'Bearer $testToken'},
        httpClient: HttpClient.new,
        storage: storage,
        stagingDir: staging,
        stallTimeout: stallTimeout,
        onStatus: onStatus,
      );

  File partial(SystemFileInfo file) =>
      File(p.join(staging.path, '${file.id}.part'));

  Future<void> seedPartial(SystemFileInfo file, List<int> bytes,
      {String? etag, int? size}) async {
    await staging.create(recursive: true);
    await partial(file).writeAsBytes(bytes);
    await File(p.join(staging.path, '${file.id}.json')).writeAsString(
        jsonEncode({'etag': etag ?? file.etag, 'size': size ?? file.size}));
  }

  List<String> stagingFiles() => staging.existsSync()
      ? ([for (final entity in staging.listSync()) p.basename(entity.path)]
        ..sort())
      : [];

  List<int>? inFolder([String name = 'synthetic-bios.bin']) =>
      storage.folders[folder.uri]![name];

  Matcher transferFailure(String message,
          {bool retryable = false, bool keepPartial = true}) =>
      throwsA(isA<SystemFileTransferException>()
          .having((e) => e.message, 'message', contains(message))
          .having((e) => e.retryable, 'retryable', retryable)
          .having((e) => e.keepPartial, 'keepPartial', keepPartial));

  Matcher romDropFailure(RomDropErrorKind kind) =>
      throwsA(isA<RomDropException>().having((e) => e.kind, 'kind', kind));

  group('a transfer', () {
    test('downloads, verifies and saves under the original name', () async {
      final statuses = <SystemFileTaskStatus>{};

      final document = await transferFor(file,
          onStatus: (status, bytes) => statuses.add(status)).run();

      expect(inFolder(), content);
      expect(document.size, content.length);
      expect(storage.saves.single,
          (folderUri: folder.uri, name: 'synthetic-bios.bin', replace: false));
      expect(statuses, [
        SystemFileTaskStatus.downloading,
        SystemFileTaskStatus.verifying,
        SystemFileTaskStatus.saving,
      ]);
      expect(stagingFiles(), isEmpty, reason: 'staging is cleared once saved');

      final request = server.requests.single;
      expect(request.uri.path, file.downloadPath);
      expect(request.uri.hasQuery, isFalse);
      expect(request.uri.toString(), isNot(contains(testToken)));
      expect(request.headers['authorization'], 'Bearer $testToken');
      expect(request.headers['accept-encoding'], 'identity');
      expect(request.headers.containsKey('range'), isFalse);
    });

    test('resumes a partial download with Range and If-Range', () async {
      await seedPartial(file, content.sublist(0, 70000));

      await transferFor(file).run();

      expect(inFolder(), content);
      final request = server.requests.single;
      expect(request.headers['range'], 'bytes=70000-');
      expect(request.headers['if-range'], file.etag);
    });

    test('goes straight to verification when everything already arrived',
        () async {
      await seedPartial(file, content);

      await transferFor(file).run();

      expect(inFolder(), content);
      expect(server.requests, isEmpty);
    });

    test('starts over when the server ignores the range', () async {
      await seedPartial(file, content.sublist(0, 70000));
      server.handler = (request) async {
        request.response
          ..headers.set('ETag', file.etag)
          ..contentLength = content.length
          ..add(content);
        await request.response.close();
      };

      await transferFor(file).run();

      expect(inFolder(), content, reason: 'nothing was appended to old bytes');
      expect(server.requests.single.headers['range'], 'bytes=70000-');
    });

    test('starts over when the 206 is not the range it asked for', () async {
      await seedPartial(file, content.sublist(0, 70000));
      server.handler = (request) async {
        if (request.headers.value('range') == null) {
          return serveSystemFile(request, content);
        }
        final tail = content.sublist(50000);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set('ETag', file.etag)
          ..headers.set('Content-Range',
              'bytes 50000-${content.length - 1}/${content.length}')
          ..contentLength = tail.length
          ..add(tail);
        await request.response.close();
      };

      await transferFor(file).run();

      expect(inFolder(), content);
      expect(server.requests, hasLength(2));
      expect(server.requests.last.headers.containsKey('range'), isFalse);
    });

    test('starts over when the range cannot be satisfied', () async {
      await seedPartial(file, content.sublist(0, 70000));
      server.handler = (request) async {
        if (request.headers.value('range') == null) {
          return serveSystemFile(request, content);
        }
        request.response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set('Content-Range', 'bytes */${content.length}');
        await request.response.close();
      };

      await transferFor(file).run();

      expect(inFolder(), content);
      expect(server.requests, hasLength(2));
    });

    test('does not resume bytes that belong to another version of the file',
        () async {
      await seedPartial(file, syntheticBytes(70000, seed: 99),
          etag: '"sha256-${'0' * 64}"');

      await transferFor(file).run();

      expect(inFolder(), content);
      expect(server.requests.single.headers.containsKey('range'), isFalse);
    });

    test('refuses a file that changed on the server', () async {
      await seedPartial(file, content.sublist(0, 70000));
      final changed = syntheticBytes(content.length, seed: 42);
      // If-Range no longer matches, so RomDrop answers 200 with the new file.
      server.handler = (request) => serveSystemFile(request, changed);

      await expectLater(transferFor(file).run(),
          transferFailure('changed on the server', keepPartial: false));

      expect(inFolder(), isNull);
      expect(stagingFiles(), isEmpty);
    });

    test('discards a download that does not match the checksum', () async {
      final tampered = List.of(content)..[1234] ^= 0x01;
      server.handler = (request) async {
        request.response
          ..headers.set('ETag', file.etag)
          ..contentLength = tampered.length
          ..add(tampered);
        await request.response.close();
      };

      await expectLater(transferFor(file).run(),
          transferFailure('does not match RomDrop\'s checksum', keepPartial: false));

      expect(inFolder(), isNull, reason: 'a bad file never reaches the folder');
      expect(storage.saves, isEmpty);
      expect(stagingFiles(), isEmpty);
    });

    test('keeps what arrived when the connection drops, then resumes',
        () async {
      server.handler =
          (request) => serveSystemFile(request, content, cutAfter: 60000);

      await expectLater(transferFor(file).run(),
          transferFailure('connection to RomDrop was lost', retryable: true));

      final kept = await partial(file).length();
      expect(kept, inInclusiveRange(1, 60000));
      expect(inFolder(), isNull);

      server.handler = (request) => serveSystemFile(request, content);
      await transferFor(file).run();

      expect(inFolder(), content);
      expect(server.requests.last.headers['range'], 'bytes=$kept-');
    });

    test('stops waiting when RomDrop stops sending', () async {
      server.handler = (request) async {
        request.response
          ..headers.set('ETag', file.etag)
          ..contentLength = content.length
          ..add(content.sublist(0, 4096));
        await request.response.flush();
        await server.stall();
      };

      await expectLater(
          transferFor(file, stallTimeout: const Duration(milliseconds: 300))
              .run(),
          transferFailure('stopped sending data', retryable: true));
      expect(inFolder(), isNull);
    });

    test('refuses more data than the file has', () async {
      server.handler = (request) async {
        // No Content-Length: the size is only known as the bytes arrive.
        request.response
          ..headers.set('ETag', file.etag)
          ..add(content)
          ..add(syntheticBytes(4096));
        await request.response.close();
      };

      await expectLater(transferFor(file).run(),
          transferFailure('more data than the file should have', keepPartial: false));
      expect(inFolder(), isNull);
    });

    test('tells the server\'s refusals apart', () async {
      Future<void> refuses(int status, String code, RomDropErrorKind kind) async {
        server.handler =
            (request) => respondJson(request, status, errorBody(code, 'Details.'));
        await expectLater(transferFor(file).run(), romDropFailure(kind),
            reason: code);
        expect(inFolder(), isNull);
      }

      await refuses(401, 'unauthorized', RomDropErrorKind.unauthorized);
      await refuses(403, 'sensitive_permission_required',
          RomDropErrorKind.sensitiveNotAllowed);
      await refuses(
          403, 'insecure_transport', RomDropErrorKind.insecureTransport);
      await refuses(404, 'not_found', RomDropErrorKind.notFound);
      await refuses(409, 'file_changed', RomDropErrorKind.fileUnavailable);
      await refuses(
          503, 'storage_unavailable', RomDropErrorKind.libraryOffline);
      await refuses(500, 'internal_error', RomDropErrorKind.server);
    });

    test('never follows a redirect', () async {
      final elsewhere = await FixtureServer.start();
      addTearDown(elsewhere.close);
      elsewhere.handler = (request) => serveSystemFile(request, content);
      server.handler = (request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('Location', '${elsewhere.url}${file.downloadPath}');
        await request.response.close();
      };

      await expectLater(
          transferFor(file).run(), romDropFailure(RomDropErrorKind.forbidden));

      expect(elsewhere.requests, isEmpty,
          reason: 'the credential must not travel to another address');
      expect(inFolder(), isNull);
    });

    test('asks nothing of the server once folder access is gone', () async {
      storage.revoked.add(folder.uri);

      await expectLater(
          transferFor(file).run(), transferFailure('no longer has access'));

      expect(server.requests, isEmpty);
    });

    test('leaves an existing file alone unless told to replace it', () async {
      final existing = syntheticBytes(64, seed: 3);
      storage.folders[folder.uri]!['synthetic-bios.bin'] = existing;

      await expectLater(
          transferFor(file).run(), transferFailure('already exists'));
      expect(server.requests, isEmpty);
      expect(inFolder(), existing);

      await transferFor(file, replace: true).run();
      expect(inFolder(), content);
      expect(storage.saves.single.replace, isTrue);
    });

    test('keeps the folders a file has inside its version', () async {
      final nested = systemFile(content,
          id: 'fil_test000000000003', name: 'dc/synthetic-boot.bin');
      // The same name directly in the folder is a different place.
      storage.folders[folder.uri]!['synthetic-boot.bin'] = [1, 2, 3];

      await transferFor(nested).run();

      expect(inFolder('dc/synthetic-boot.bin'), content);
      expect(inFolder('synthetic-boot.bin'), [1, 2, 3]);
      await expectLater(transferFor(nested).run(),
          transferFailure('"dc/synthetic-boot.bin" already exists'));
    });

    test('removes a copy that did not arrive intact in the folder', () async {
      storage.corruptOnSave = true;

      await expectLater(
          transferFor(file).run(), transferFailure('did not arrive intact'));

      expect(inFolder(), isNull);
      expect(storage.deleted, hasLength(1));
    });

    test('does not fetch what the server marks unavailable', () async {
      await expectLater(transferFor(systemFile(content, state: 'changed')).run(),
          transferFailure('not available on the server'));
      await expectLater(transferFor(systemFile(content, state: 'missing')).run(),
          transferFailure('not available on the server'));
      expect(server.requests, isEmpty);
    });

    test('does not unpack: an archive is saved exactly as stored', () async {
      await expectLater(transferFor(systemFile(content, extract: true)).run(),
          transferFailure('unpacked'));
      expect(server.requests, isEmpty);

      final archive = systemFile(content,
          id: 'fil_test000000000002', name: 'Firmware 19.0.1.zip');
      await transferFor(archive).run();
      expect(inFolder('Firmware 19.0.1.zip'), content);
    });
  });

  group('the queue', () {
    late RomDropApiService api;

    setUp(() => api = RomDropApiService(baseUrl: server.url, token: testToken));

    SystemFileDownloadManager managerWith({
      RomDropApiService? Function()? connection,
      List<Duration> retryDelays = const [
        Duration(milliseconds: 20),
        Duration(milliseconds: 20),
      ],
      void Function(bool busy)? onBusyChanged,
    }) {
      final manager = SystemFileDownloadManager(
        storage: storage,
        saved: saved,
        stagingDirectory: () async => staging,
        api: connection ?? () => api,
        prefs: prefs,
        retryDelays: retryDelays,
        onBusyChanged: onBusyChanged,
      );
      addTearDown(manager.dispose);
      return manager;
    }

    Future<void> until(bool Function() condition, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    /// Waits until nothing is running, queued or waiting to retry.
    Future<SystemFileTask> settled(
        SystemFileDownloadManager manager, SystemFileInfo file) async {
      await until(
          () => !manager.busy && (manager.task(file.id)?.status.finished ?? false),
          '${file.filename}: ${manager.task(file.id)?.status}');
      return manager.task(file.id)!;
    }

    test('saves the file and remembers where it went', () async {
      final busy = <bool>[];
      final manager = managerWith(onBusyChanged: busy.add);

      manager.enqueue(requestFor(file));
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.completed);
      expect(task.statusText, 'Saved to ${folder.name}');
      expect(task.progress, 1.0);
      expect(inFolder(), content);
      final record = saved[file.id]!;
      expect(record.filename, 'synthetic-bios.bin');
      expect(record.relativePath, 'synthetic-bios.bin');
      expect(record.folderUri, folder.uri);
      expect(record.sha256, file.sha256);
      expect(record.importConfirmed, isFalse,
          reason: 'saving a file is not importing it into an emulator');
      expect(busy, [true, false]);
      expect(prefs.getString('system_file_tasks'), isNull,
          reason: 'nothing is left to continue');
    });

    test('retries by itself after a dropped connection and resumes', () async {
      var first = true;
      server.handler = (request) {
        final cut = first ? 60000 : null;
        first = false;
        return serveSystemFile(request, content, cutAfter: cut);
      };
      final manager = managerWith();

      manager.enqueue(requestFor(file));
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.completed);
      expect(task.attempts, 2);
      expect(inFolder(), content);
      expect(server.requests, hasLength(2));
      expect(server.requests.last.headers['range'], startsWith('bytes='));
      expect(server.requests.last.headers['if-range'], file.etag);
    });

    test('stops retrying after the configured attempts and keeps the partial',
        () async {
      server.handler =
          (request) => serveSystemFile(request, content, cutAfter: 30000);
      final manager = managerWith();

      manager.enqueue(requestFor(file));
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.failed);
      expect(task.error, contains('connection to RomDrop was lost'));
      expect(server.requests, hasLength(3)); // the first try and two retries
      expect(inFolder(), isNull);
      expect(await partial(file).exists(), isTrue);
      expect(saved[file.id], isNull);
    });

    test('a failed download continues from the partial when asked', () async {
      server.handler =
          (request) => serveSystemFile(request, content, cutAfter: 60000);
      final manager = managerWith(retryDelays: const []);
      manager.enqueue(requestFor(file));
      expect((await settled(manager, file)).status, SystemFileTaskStatus.failed);
      final kept = await partial(file).length();

      server.handler = (request) => serveSystemFile(request, content);
      manager.retry(file.id);
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.completed);
      expect(inFolder(), content);
      expect(server.requests.last.headers['range'], 'bytes=$kept-');
    });

    test('does not retry a device RomDrop no longer accepts', () async {
      server.handler = (request) =>
          serveSystemFile(request, content, token: 'rdt_another-credential');
      final manager = managerWith();

      manager.enqueue(requestFor(file));
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.failed);
      expect(task.errorKind, RomDropErrorKind.unauthorized);
      expect(task.error, contains('Pair it again'));
      expect(server.requests, hasLength(1));
      expect(inFolder(), isNull);
    });

    test('a checksum mismatch fails without leaving anything behind', () async {
      final tampered = List.of(content)..[10] ^= 0x01;
      server.handler = (request) async {
        request.response
          ..headers.set('ETag', file.etag)
          ..contentLength = tampered.length
          ..add(tampered);
        await request.response.close();
      };
      final manager = managerWith();

      manager.enqueue(requestFor(file));
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.failed);
      expect(task.error, contains('checksum'));
      expect(server.requests, hasLength(1), reason: 'not retried unattended');
      expect(inFolder(), isNull);
      expect(stagingFiles(), isEmpty);
      expect(saved[file.id], isNull);
    });

    test('cancelling a download removes the partial', () async {
      server.handler = (request) async {
        request.response
          ..headers.set('ETag', file.etag)
          ..contentLength = content.length
          ..add(content.sublist(0, 50000));
        await request.response.flush();
        await server.stall();
      };
      final manager = managerWith();
      manager.enqueue(requestFor(file));
      await until(
          () => partial(file).existsSync() && partial(file).lengthSync() > 0,
          'the first bytes');

      await manager.cancel(file.id);
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.cancelled);
      expect(inFolder(), isNull);
      expect(stagingFiles(), isEmpty);
      expect(saved[file.id], isNull);
      expect(prefs.getString('system_file_tasks'), isNull);
    });

    test('cancelling while the file is being copied leaves nothing', () async {
      storage.saveGate = Completer<void>();
      final manager = managerWith();
      manager.enqueue(requestFor(file));
      await until(
          () => manager.task(file.id)?.status == SystemFileTaskStatus.saving,
          'the copy to start');

      await manager.cancel(file.id);
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.cancelled);
      expect(inFolder(), isNull);
      expect(saved[file.id], isNull);
      expect(stagingFiles(), isEmpty);
    });

    test('runs one transfer at a time, in the order they were asked for',
        () async {
      final second = systemFile(syntheticBytes(4096, seed: 5),
          id: 'fil_test000000000002', name: 'second.bin');
      final bodies = {
        file.downloadPath: content,
        second.downloadPath: syntheticBytes(4096, seed: 5),
      };
      var inFlight = 0;
      var mostAtOnce = 0;
      server.handler = (request) async {
        inFlight++;
        if (inFlight > mostAtOnce) mostAtOnce = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await serveSystemFile(request, bodies[request.uri.path]!);
        inFlight--;
      };
      final manager = managerWith();

      manager.enqueue(requestFor(file));
      manager.enqueue(requestFor(second));
      await settled(manager, second);

      expect(mostAtOnce, 1);
      expect(server.requests.map((r) => r.uri.path),
          [file.downloadPath, second.downloadPath]);
      expect(manager.tasks.map((t) => t.status).toSet(),
          {SystemFileTaskStatus.completed});
      expect(manager.tasks.first.id, second.id, reason: 'newest listed first');
    });

    test('asking twice for a file in progress starts it once', () async {
      final manager = managerWith();

      manager.enqueue(requestFor(file));
      manager.enqueue(requestFor(file));
      await settled(manager, file);

      expect(manager.tasks, hasLength(1));
      expect(server.requests, hasLength(1));
    });

    test('says so when RomDrop is not connected', () async {
      final manager = managerWith(connection: () => null);

      manager.enqueue(requestFor(file));
      final task = await settled(manager, file);

      expect(task.status, SystemFileTaskStatus.failed);
      expect(task.errorKind, RomDropErrorKind.notConfigured);
      expect(server.requests, isEmpty);
    });

    test('finished entries can be dismissed, running ones cannot', () async {
      server.handler = (request) async {
        request.response
          ..headers.set('ETag', file.etag)
          ..contentLength = content.length
          ..add(content.sublist(0, 1000));
        await request.response.flush();
        await server.stall();
      };
      final manager = managerWith();
      manager.enqueue(requestFor(file));
      await until(() => manager.task(file.id)?.status.active ?? false,
          'the download to start');

      manager.dismiss(file.id);
      expect(manager.task(file.id), isNotNull);

      await manager.cancel(file.id);
      await settled(manager, file);
      manager.dismiss(file.id);
      expect(manager.tasks, isEmpty);
    });

    group('after the app was closed mid-download', () {
      test('offers the download again and continues from the partial',
          () async {
        server.handler =
            (request) => serveSystemFile(request, content, cutAfter: 60000);
        final before = managerWith(retryDelays: const []);
        before.enqueue(requestFor(file));
        await settled(before, file);
        final kept = await partial(file).length();
        // A partial nobody will ever continue.
        await File(p.join(staging.path, 'fil_orphan.part')).writeAsBytes([1, 2]);
        await File(p.join(staging.path, 'fil_orphan.json')).writeAsString('{}');

        final stored = prefs.getString('system_file_tasks')!;
        expect(stored, contains(file.id));
        expect(stored, isNot(contains('rdt_')),
            reason: 'the credential is never written with the task');

        final after = managerWith();
        await after.restore();

        final restored = after.task(file.id)!;
        expect(restored.status, SystemFileTaskStatus.failed);
        expect(restored.error, contains('Interrupted'));
        expect(after.busy, isFalse, reason: 'nothing restarts by itself');
        expect(server.requests, hasLength(1));
        expect(stagingFiles(), ['${file.id}.json', '${file.id}.part']);

        server.handler = (request) => serveSystemFile(request, content);
        after.retry(file.id);
        final task = await settled(after, file);

        expect(task.status, SystemFileTaskStatus.completed);
        expect(inFolder(), content);
        expect(server.requests.last.headers['range'], 'bytes=$kept-');
      });

      test('an unreadable task list is dropped, not fatal', () async {
        await prefs.setString('system_file_tasks', '{not json');

        final manager = managerWith();
        await manager.restore();

        expect(manager.tasks, isEmpty);
        expect(prefs.getString('system_file_tasks'), isNull);
      });
    });
  });
}
