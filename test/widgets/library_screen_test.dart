import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/library/library_screen.dart';
import 'package:retro_eshop/features/library/widgets/library_section_header.dart';
import 'package:retro_eshop/l10n/app_localizations.dart';
import 'package:retro_eshop/models/config/app_config.dart';
import 'package:retro_eshop/models/config/provider_config.dart';
import 'package:retro_eshop/models/config/source.dart';
import 'package:retro_eshop/models/config/system_config.dart';
import 'package:retro_eshop/providers/app_providers.dart';
import 'package:retro_eshop/providers/game_providers.dart';
import 'package:retro_eshop/providers/installed_files_provider.dart';
import 'package:retro_eshop/providers/rom_status_providers.dart';
import 'package:retro_eshop/services/audio_manager.dart';
import 'package:retro_eshop/services/config_storage_service.dart';
import 'package:retro_eshop/services/database_service.dart';
import 'package:retro_eshop/services/device_info_service.dart';
import 'package:retro_eshop/services/feedback_service.dart';
import 'package:retro_eshop/services/haptic_service.dart';
import 'package:retro_eshop/services/input_debouncer.dart';
import 'package:retro_eshop/services/sources_notifier.dart';
import 'package:retro_eshop/services/storage_service.dart';
import 'package:retro_eshop/widgets/base_game_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _SilentFeedback extends FeedbackService {
  _SilentFeedback() : super(AudioManager(), HapticService());

  @override
  void tick() {}
  @override
  void confirm() {}
  @override
  void cancel() {}
  @override
  void error() {}
}

/// No cooldown between presses, so a test can press as fast as it likes.
class _InstantDebouncer extends InputDebouncer {
  @override
  bool canPerformAction() => true;

  @override
  bool startHold(VoidCallback action) {
    action();
    return true;
  }
}

class _StubSourcesNotifier extends SourcesNotifier {
  _StubSourcesNotifier()
      : super(ConfigStorageService(
          directoryProvider: () async =>
              Directory.systemTemp.createTempSync('rshop_library_screen_'),
        )) {
    state = const SourcesState(sources: <Source>[], loading: false);
  }
}

/// Platforms without box-art lookups, so tiles never touch the network: one
/// built-in system and one the app has no entry for (shown by its id).
const _pico = 'pico8'; // "PICO-8"
const _other = 'unlisted'; // "UNLISTED"

void main() {
  late Database db;
  late StorageService storage;

  setUpAll(sqfliteFfiInit);

  Future<void> addGame(String system, String filename,
      {bool remote = true}) async {
    await db.insert('games', {
      'systemSlug': system,
      'filename': filename,
      'displayName': filename,
      'url': remote ? 'http://server/$filename' : '',
    });
  }

  setUp(() async {
    db = await databaseFactoryFfiNoIsolate.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE games (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            systemSlug TEXT NOT NULL,
            filename TEXT NOT NULL,
            displayName TEXT NOT NULL,
            url TEXT NOT NULL,
            cover_url TEXT,
            provider_config TEXT,
            has_thumbnail INTEGER NOT NULL DEFAULT 0
          )
        '''),
      ),
    );
    DatabaseService.testDatabase = db;
    // PICO-8: Alpha and Bravo installed, Charlie only on the server.
    await addGame(_pico, 'Alpha.p8');
    await addGame(_pico, 'Bravo.p8');
    await addGame(_pico, 'Charlie.p8');
    // Unlisted platform: Delta installed, Echo only on the server.
    await addGame(_other, 'Delta.p8');
    await addGame(_other, 'Echo.p8');
  });

  tearDown(() async {
    DatabaseService.resetForTesting();
    await db.close();
  });

  /// [installed] are the filenames on the device; [scanDir] reads them from
  /// a real folder instead, so deleting files is seen.
  Future<void> pumpLibrary(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    int? savedColumns = 6,
    Set<String> installed = const {'Alpha.p8', 'Bravo.p8', 'Delta.p8'},
    AppConfig config = AppConfig.empty,
    Directory? scanDir,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      if (savedColumns != null) 'grid_columns_library_covers': savedColumns,
      ...prefs,
    });
    FlutterSecureStorage.setMockInitialValues({});
    storage = StorageService();
    await storage.init();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        feedbackServiceProvider.overrideWithValue(_SilentFeedback()),
        inputDebouncerProvider.overrideWithValue(_InstantDebouncer()),
        deviceMemoryProvider.overrideWithValue(const DeviceMemoryInfo(
            totalBytes: 8 * 1024 * 1024 * 1024, tier: MemoryTier.high)),
        sourcesProvider.overrideWith((ref) => _StubSourcesNotifier()),
        bootstrappedConfigProvider.overrideWith((ref) async => config),
        installedFilesProvider.overrideWith((ref) async {
          ref.watch(romChangeSignalProvider);
          return InstalledFilesState(
              all: scanDir == null
                  ? installed
                  : {
                      for (final f in scanDir.listSync())
                        f.uri.pathSegments.last,
                    });
        }),
      ],
      child: MaterialApp(
        localizationsDelegates: L.localizationsDelegates,
        supportedLocales: L.supportedLocales,
        home: const LibraryScreen(),
      ),
    ));
    // First frame, then the DB load and the installed-files result.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  List<LibrarySectionHeader> headers(WidgetTester tester) => tester
      .widgetList<LibrarySectionHeader>(find.byType(LibrarySectionHeader))
      .toList();

  List<BaseGameCard> cards(WidgetTester tester) =>
      tester.widgetList<BaseGameCard>(find.byType(BaseGameCard)).toList();

  String? selectedCard(WidgetTester tester) => cards(tester)
      .where((c) => c.isSelected)
      .map((c) => c.displayName)
      .firstOrNull;

  String? selectedHeader(WidgetTester tester) => headers(tester)
      .where((h) => h.isSelected)
      .map((h) => h.title)
      .firstOrNull;

  int tabCount(WidgetTester tester, String label) {
    final row = find.ancestor(of: find.text(label), matching: find.byType(Row));
    final texts = tester
        .widgetList<Text>(find.descendant(of: row.first, matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
    return int.parse(texts.last!);
  }

  testWidgets('opens on Installed with every platform collapsed',
      (tester) async {
    await pumpLibrary(tester);

    expect(tabCount(tester, 'INSTALLED'), 3);
    expect(tabCount(tester, 'AVAILABLE'), 2);
    expect(tabCount(tester, 'ALL'), 5);

    expect(headers(tester).map((h) => '${h.title} ${h.count}'),
        ['PICO-8 2', 'UNLISTED 1']);
    expect(headers(tester).every((h) => !h.expanded), isTrue);
    expect(cards(tester), isEmpty);
    expect(selectedHeader(tester), 'PICO-8');
    expect(find.text('Expand'), findsOneWidget);
    expect(find.text('RECENTLY PLAYED'), findsNothing);
  });

  testWidgets('A expands a platform and the d-pad walks its games',
      (tester) async {
    await pumpLibrary(tester);

    await press(tester, LogicalKeyboardKey.enter);
    expect(headers(tester).first.expanded, isTrue);
    expect(cards(tester).map((c) => c.displayName), ['Alpha', 'Bravo']);
    expect(find.text('Collapse'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selectedCard(tester), 'Alpha');
    expect(find.text('Select'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(selectedCard(tester), 'Bravo');
    // Right edge of the row: stays put.
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(selectedCard(tester), 'Bravo');

    // Down from the grid reaches the next platform, up returns to the
    // column that was left.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selectedHeader(tester), 'UNLISTED');
    expect(selectedCard(tester), isNull);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(selectedCard(tester), 'Bravo');

    // Collapsing from the header hides the games again.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(selectedHeader(tester), 'PICO-8');
    await press(tester, LogicalKeyboardKey.enter);
    expect(cards(tester), isEmpty);
  });

  testWidgets('tabs cycle Installed, Available, All', (tester) async {
    await pumpLibrary(tester);

    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(headers(tester).map((h) => '${h.title} ${h.count}'),
        ['PICO-8 1', 'UNLISTED 1']);
    await press(tester, LogicalKeyboardKey.enter);
    expect(cards(tester).map((c) => c.displayName), ['Charlie']);

    // Each tab remembers its own expanded platforms.
    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(headers(tester).map((h) => '${h.title} ${h.count}'),
        ['PICO-8 3', 'UNLISTED 2']);
    expect(cards(tester), isEmpty);
    await press(tester, LogicalKeyboardKey.bracketLeft);
    expect(cards(tester).map((c) => c.displayName), ['Charlie']);
  });

  testWidgets('recently played games sit above the platforms', (tester) async {
    await pumpLibrary(tester, prefs: {
      'recently_played': jsonEncode([
        {'s': _other, 'f': 'Delta.p8', 't': 3},
        // Played but since uninstalled: not offered.
        {'s': _pico, 'f': 'Charlie.p8', 't': 2},
        {'s': _pico, 'f': 'Alpha.p8', 't': 1},
      ]),
    });

    expect(find.text('RECENTLY PLAYED'), findsOneWidget);
    expect(cards(tester).map((c) => c.displayName), ['Delta', 'Alpha']);
    // The cursor starts on the most recent game.
    expect(selectedCard(tester), 'Delta');

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(selectedCard(tester), 'Alpha');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selectedHeader(tester), 'PICO-8');
    // Back up returns to the tile that was left.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(selectedCard(tester), 'Alpha');
  });

  testWidgets('X marks games, a whole platform, and asks before uninstalling',
      (tester) async {
    await pumpLibrary(tester);
    expect(find.text('Multi-select'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.enter);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.gameButtonX);
    expect(find.text('Uninstall (1)'), findsOneWidget);
    expect(find.text('1 MARKED TO UNINSTALL'), findsOneWidget);

    // A toggles the mark while selecting instead of opening the game.
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('Uninstall (0)'), findsOneWidget);

    // X on a platform marks all of its installed games.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(find.text('Mark platform'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.gameButtonX);
    expect(find.text('Uninstall (2)'), findsOneWidget);
    expect(headers(tester).first.markedCount, 2);

    // Tabs are locked while selecting.
    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(headers(tester).first.count, 2);

    // Y asks first; Cancel is the default choice.
    await press(tester, LogicalKeyboardKey.keyI);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Uninstall 2 games?'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Uninstall 2 games?'), findsNothing);
    expect(find.text('Uninstall (2)'), findsOneWidget);

    // B leaves multi-select without touching anything.
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('Multi-select'), findsOneWidget);
    expect(tabCount(tester, 'INSTALLED'), 3);
  });

  testWidgets('the page scrolls to keep the cursor on screen', (tester) async {
    final names = [
      for (var i = 0; i < 40; i++) 'Game ${i.toString().padLeft(2, '0')}.p8',
    ];
    await tester.runAsync(() async {
      for (final name in names) {
        await addGame(_pico, name);
      }
    });
    await pumpLibrary(tester, installed: names.toSet());
    expect(headers(tester).single.count, 40);

    Rect selectedRect() => tester.getRect(
        find.byWidgetPredicate((w) => w is BaseGameCard && w.isSelected));

    // 6 columns: six presses down from the header reach the sixth row,
    // far below the first screen.
    await press(tester, LogicalKeyboardKey.enter);
    for (var i = 0; i < 6; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(selectedCard(tester), 'Game 30');
    expect(selectedRect().top, greaterThanOrEqualTo(96));
    expect(selectedRect().bottom, lessThanOrEqualTo(800));

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(selectedCard(tester), 'Game 31');
    // The last row is short: the column is clamped, then restored going up.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selectedCard(tester), 'Game 37');
    expect(selectedRect().bottom, lessThanOrEqualTo(800));

    for (var i = 0; i < 7; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(selectedHeader(tester), 'PICO-8');
    expect(
        tester.getRect(find.byType(LibrarySectionHeader)).top,
        greaterThanOrEqualTo(96));
  });

  testWidgets('tile size fits the screen until L or R picks a zoom level',
      (tester) async {
    final names = [for (var i = 0; i < 20; i++) 'Game ${i + 10}.p8'];
    await tester.runAsync(() async {
      for (final name in names) {
        await addGame(_pico, name);
      }
    });
    await pumpLibrary(tester, installed: names.toSet(), savedColumns: null);
    await press(tester, LogicalKeyboardKey.enter);

    int tilesInFirstRow() {
      final tops = cards(tester)
          .map((c) => tester.getRect(find.byWidget(c)).top)
          .toList();
      return tops.where((top) => top == tops.first).length;
    }

    // 1280 wide: eight covers of about 145 fit.
    expect(tilesInFirstRow(), 8);
    expect(storage.getGridColumns('library_covers', fallback: 0), 0);

    await press(tester, LogicalKeyboardKey.pageDown);
    expect(tilesInFirstRow(), 7);
    expect(storage.getGridColumns('library_covers', fallback: 0), 7);
  });

  testWidgets('uninstalling deletes only the marked games', (tester) async {
    final dir = Directory.systemTemp.createTempSync('rshop_library_uninstall_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final alpha = File('${dir.path}/Alpha.p8')..writeAsStringSync('rom');
    final bravo = File('${dir.path}/Bravo.p8')..writeAsStringSync('rom');

    await pumpLibrary(
      tester,
      scanDir: dir,
      config: AppConfig(systems: [
        SystemConfig(
          id: _pico,
          name: 'PICO-8',
          targetFolder: dir.path,
          providers: const [
            ProviderConfig(
                type: ProviderType.web, priority: 1, url: 'http://server'),
          ],
        ),
      ]),
    );
    expect(tabCount(tester, 'INSTALLED'), 2);

    await press(tester, LogicalKeyboardKey.enter);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.gameButtonX);
    expect(find.text('Uninstall (1)'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.keyI);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Uninstall 1 game?'), findsOneWidget);

    // Choose UNINSTALL; the deletion is real file I/O.
    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(alpha.existsSync(), isFalse);
    expect(bravo.existsSync(), isTrue);
    expect(find.text('Uninstalled 1 game.'), findsOneWidget);
    expect(find.text('Multi-select'), findsOneWidget);
    expect(tabCount(tester, 'INSTALLED'), 1);
    // Alpha is still in the library, now as a download.
    expect(tabCount(tester, 'AVAILABLE'), 4);
    expect(tabCount(tester, 'ALL'), 5);

    // Let the notification finish.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('search shows one flat list and restores the platforms after',
      (tester) async {
    await pumpLibrary(tester);

    await press(tester, LogicalKeyboardKey.keyI);
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(milliseconds: 200));
    // Installed games whose title contains "a".
    expect(headers(tester), isEmpty);
    expect(cards(tester).map((c) => c.displayName),
        ['Alpha', 'Bravo', 'Delta']);

    // B leaves the text field first, then closes the search.
    await press(tester, LogicalKeyboardKey.escape);
    await press(tester, LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 200));
    expect(headers(tester).map((h) => h.title), ['PICO-8', 'UNLISTED']);
    expect(cards(tester), isEmpty);
  });
}
