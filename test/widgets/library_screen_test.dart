import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_eshop/features/library/library_screen.dart';
import 'package:retro_eshop/features/library/widgets/library_section_header.dart';
import 'package:retro_eshop/features/library/widgets/library_tabs.dart';
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
import 'package:retro_eshop/widgets/exit_confirmation_overlay.dart';
import 'package:retro_eshop/widgets/quick_menu.dart';
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

/// Stands in for the console list when the library is opened from it.
class _ConsoleList extends StatefulWidget {
  const _ConsoleList();

  @override
  State<_ConsoleList> createState() => _ConsoleListState();
}

class _ConsoleListState extends State<_ConsoleList> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.push(context,
        MaterialPageRoute<void>(builder: (_) => const LibraryScreen())));
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('console list')));
}

/// Platforms without box-art lookups, so tiles never touch the network: one
/// built-in system and ones the app has no entry for (shown by their id).
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
    bool topLevel = false,
    bool fromConsoleList = false,
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
        home: fromConsoleList
            ? const _ConsoleList()
            : LibraryScreen(topLevel: topLevel),
      ),
    ));
    // First frame, then the DB load and the installed-files result.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key,
      {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// An overlay hands the keys back a moment after it is gone.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  List<LibrarySectionHeader> headers(WidgetTester tester) => tester
      .widgetList<LibrarySectionHeader>(find.byType(LibrarySectionHeader))
      .toList();

  List<BaseGameCard> cards(WidgetTester tester) =>
      tester.widgetList<BaseGameCard>(find.byType(BaseGameCard)).toList();

  List<String> titles(WidgetTester tester) =>
      cards(tester).map((c) => c.displayName).toList();

  final selected =
      find.byWidgetPredicate((w) => w is BaseGameCard && w.isSelected);

  String? selectedCard(WidgetTester tester) => cards(tester)
      .where((c) => c.isSelected)
      .map((c) => c.displayName)
      .firstOrNull;

  String? selectedHeader(WidgetTester tester) => headers(tester)
      .where((h) => h.isSelected)
      .map((h) => h.title)
      .firstOrNull;

  int tabCount(WidgetTester tester, String label) {
    final tab = find.descendant(
        of: find.byType(LibraryTabs), matching: find.text(label));
    final row = find.ancestor(of: tab, matching: find.byType(Row)).first;
    final texts = tester
        .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
    return int.parse(texts.last!);
  }

  testWidgets('opens on All: platforms expanded, installed games first',
      (tester) async {
    // Sorts before the installed games by name, but is not installed.
    await tester.runAsync(() => addGame(_pico, 'Aardvark.p8'));
    await pumpLibrary(tester);

    final labels = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(LibraryTabs), matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();
    expect(labels,
        ['ALL', '6', 'INSTALLED', '3', 'AVAILABLE', '3', 'FAVORITES', '0']);

    expect(headers(tester).map((h) => '${h.title} ${h.count}'),
        ['PICO-8 4', 'UNLISTED 2']);
    expect(headers(tester).every((h) => h.expanded), isTrue);
    expect(titles(tester),
        ['Alpha', 'Bravo', 'Aardvark', 'Charlie', 'Delta', 'Echo']);

    // Installed tiles glow green, the ones only on the server light blue.
    expect(cards(tester).map((c) => c.glowColor), [
      Colors.greenAccent,
      Colors.greenAccent,
      Colors.lightBlueAccent,
      Colors.lightBlueAccent,
      Colors.greenAccent,
      Colors.lightBlueAccent,
    ]);
    expect(cards(tester).every((c) => !c.isInstalled), isTrue);

    // The cursor starts on a game; nothing has been played yet.
    expect(selectedCard(tester), 'Alpha');
    expect(find.text('Select'), findsOneWidget);
    expect(find.text('RECENTLY PLAYED'), findsOneWidget);
    expect(find.textContaining('Nothing yet'), findsOneWidget);
  });

  testWidgets('a platform is one sideways row and collapses from its label',
      (tester) async {
    await pumpLibrary(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(selectedCard(tester), 'Bravo');
    await press(tester, LogicalKeyboardKey.arrowRight, times: 2);
    // End of the row: stays put.
    expect(selectedCard(tester), 'Charlie');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selectedHeader(tester), 'UNLISTED');
    expect(find.text('Collapse'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selectedCard(tester), 'Delta');

    // Going back up returns to the game the first row was left on.
    await press(tester, LogicalKeyboardKey.arrowUp, times: 2);
    expect(selectedCard(tester), 'Charlie');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(selectedHeader(tester), 'PICO-8');
    await press(tester, LogicalKeyboardKey.enter);
    expect(headers(tester).first.expanded, isFalse);
    expect(titles(tester), ['Delta', 'Echo']);
    expect(find.text('Expand'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.enter);
    expect(titles(tester), ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo']);
  });

  testWidgets('tabs cycle All, Installed, Available', (tester) async {
    await pumpLibrary(tester);

    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(headers(tester).map((h) => '${h.title} ${h.count}'),
        ['PICO-8 2', 'UNLISTED 1']);
    expect(titles(tester), ['Alpha', 'Bravo', 'Delta']);

    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(titles(tester), ['Charlie', 'Echo']);

    // Each tab remembers which platforms it has collapsed.
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.enter);
    expect(titles(tester), ['Echo']);
    await press(tester, LogicalKeyboardKey.bracketLeft);
    expect(titles(tester), ['Alpha', 'Bravo', 'Delta']);
    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(titles(tester), ['Echo']);
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
    expect(find.textContaining('Nothing yet'), findsNothing);
    expect(titles(tester),
        ['Delta', 'Alpha', 'Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo']);
    // The cursor starts on the most recent game.
    expect(cards(tester).indexWhere((c) => c.isSelected), 0);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(cards(tester).indexWhere((c) => c.isSelected), 1);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selectedHeader(tester), 'PICO-8');
    // Back up returns to the tile that was left.
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(cards(tester).indexWhere((c) => c.isSelected), 1);
  });

  testWidgets('X marks games, a whole platform, and asks before uninstalling',
      (tester) async {
    await pumpLibrary(tester);
    expect(find.text('Multi-select'), findsOneWidget);

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

    // A game that is not installed cannot be marked.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight, times: 2);
    expect(selectedCard(tester), 'Charlie');
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('Uninstall (2)'), findsOneWidget);

    // Tabs are locked while selecting.
    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(headers(tester).first.count, 3);

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

  testWidgets('rows and the page scroll to keep the cursor on screen',
      (tester) async {
    final names = [
      for (var i = 0; i < 30; i++) 'Game ${i.toString().padLeft(2, '0')}.p8',
    ];
    await tester.runAsync(() async {
      for (final name in names) {
        await addGame(_pico, name);
      }
      for (final platform in ['unlisted-b', 'unlisted-c', 'unlisted-d']) {
        await addGame(platform, 'Only $platform.p8');
      }
    });
    await pumpLibrary(tester, installed: names.toSet());

    void expectOnScreen() {
      final rect = tester.getRect(selected);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1280));
      expect(rect.top, greaterThanOrEqualTo(96));
      expect(rect.bottom, lessThanOrEqualTo(800));
    }

    // Far along the first platform's row.
    expect(selectedCard(tester), 'Game 00');
    await press(tester, LogicalKeyboardKey.arrowRight, times: 14);
    expect(selectedCard(tester), 'Game 14');
    expectOnScreen();
    // The start of the row has scrolled away.
    expect(find.text('Game 00'), findsNothing);

    // Down through four more platforms: a header and a row each.
    await press(tester, LogicalKeyboardKey.arrowDown, times: 8);
    expect(selectedCard(tester), 'Only unlisted-d');
    expectOnScreen();

    // Back at the top the first row is where it was left.
    await press(tester, LogicalKeyboardKey.arrowUp, times: 8);
    expect(selectedCard(tester), 'Game 14');
    expectOnScreen();
  });

  testWidgets('tile size fits the screen until L or R picks a zoom level',
      (tester) async {
    await pumpLibrary(tester, savedColumns: null);

    double tileWidth() => tester.getSize(find.byType(BaseGameCard).first).width;

    // 1280 wide: eight whole covers of about 145 and a slice of a ninth.
    expect(tileWidth(), closeTo((1280 - 24 - 8 * 14) / 8.35, 0.01));
    expect(storage.getGridColumns('library_covers', fallback: 0), 0);

    await press(tester, LogicalKeyboardKey.pageDown);
    expect(tileWidth(), closeTo((1280 - 24 - 7 * 14) / 7.35, 0.01));
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
    expect(selectedCard(tester), 'Alpha');

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
    expect(tabCount(tester, 'AVAILABLE'), 4);
    expect(tabCount(tester, 'ALL'), 5);
    // Alpha stays in the library as a download, after the installed games.
    expect(titles(tester).take(3), ['Bravo', 'Alpha', 'Charlie']);
    expect(cards(tester)[1].glowColor, Colors.lightBlueAccent);

    // Let the notification finish.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
  });

  group('as a top-level view', () {
    testWidgets('Back asks to leave the app, and Back again takes it away',
        (tester) async {
      await pumpLibrary(tester, topLevel: true);
      expect(find.text('Exit'), findsOneWidget, reason: 'the B hint');
      expect(find.text('Back'), findsNothing);

      await press(tester, LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ExitConfirmationOverlay), findsOneWidget);
      expect(find.byType(LibraryScreen), findsOneWidget);

      // B answers the question with "no".
      await press(tester, LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(ExitConfirmationOverlay), findsNothing);
    });

    testWidgets('Android\'s back gesture does the same', (tester) async {
      await pumpLibrary(tester, topLevel: true);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ExitConfirmationOverlay), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(ExitConfirmationOverlay), findsNothing);
      expect(find.byType(LibraryScreen), findsOneWidget);
    });

    testWidgets('the menu has the entries the console list has',
        (tester) async {
      await pumpLibrary(
        tester,
        topLevel: true,
        config: const AppConfig(systems: [
          SystemConfig(
              id: _pico, name: 'PICO-8', targetFolder: '/roms/pico8', providers: []),
          SystemConfig(
              id: 'nes', name: 'NES', targetFolder: '/roms/nes', providers: []),
        ]),
      );

      await press(tester, LogicalKeyboardKey.gameButtonStart);
      await tester.pump(const Duration(milliseconds: 400));
      final menu = find.byType(QuickMenuOverlay);
      for (final label in ['Platforms', 'Sync All', 'System Files', 'Settings']) {
        expect(find.descendant(of: menu, matching: find.text(label)),
            findsOneWidget,
            reason: label);
      }
      // No RetroArr source is set up here, so there is nothing to scan.
      expect(find.text('Scan RetroArr library'), findsNothing);

      await press(tester, LogicalKeyboardKey.escape);
      await settle(tester);
    });

    testWidgets('a menu taller than the screen keeps the cursor in view',
        (tester) async {
      await pumpLibrary(tester, topLevel: true);
      // A short, wide screen: a tablet on its side.
      tester.view.physicalSize = const Size(1280, 420);
      await tester.pump();

      await press(tester, LogicalKeyboardKey.gameButtonStart);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull, reason: 'the panel must not overflow');
      await press(tester, LogicalKeyboardKey.arrowDown, times: 12);
      await tester.pump(const Duration(milliseconds: 300));

      final settings = find.descendant(
          of: find.byType(QuickMenuOverlay), matching: find.text('Settings'));
      expect(tester.getRect(settings).bottom, lessThanOrEqualTo(420));
      expect(tester.getRect(settings).top, greaterThanOrEqualTo(0));

      await press(tester, LogicalKeyboardKey.escape);
      await settle(tester);
    });
  });

  testWidgets('opened from the console list, Back returns to it',
      (tester) async {
    await pumpLibrary(tester, fromConsoleList: true);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.text('Back'), findsOneWidget, reason: 'the B hint');

    await press(tester, LogicalKeyboardKey.gameButtonStart);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Platforms'), findsNothing,
        reason: 'Back already leads to the console list');
    await press(tester, LogicalKeyboardKey.escape);
    await settle(tester);

    await press(tester, LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(ExitConfirmationOverlay), findsNothing);
    expect(find.byType(LibraryScreen), findsNothing);
    expect(find.text('console list'), findsOneWidget);
  });

  testWidgets('search shows one flat grid and restores the platforms after',
      (tester) async {
    await pumpLibrary(tester);

    await press(tester, LogicalKeyboardKey.keyI);
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(milliseconds: 200));
    // Every game whose title contains "a", by name.
    expect(headers(tester), isEmpty);
    expect(titles(tester), ['Alpha', 'Bravo', 'Charlie', 'Delta']);
    expect(find.text('RECENTLY PLAYED'), findsNothing);

    // B leaves the text field first, then closes the search.
    await press(tester, LogicalKeyboardKey.escape, times: 2);
    await tester.pump(const Duration(milliseconds: 200));
    expect(headers(tester).map((h) => h.title), ['PICO-8', 'UNLISTED']);
    expect(titles(tester), ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo']);
  });
}
